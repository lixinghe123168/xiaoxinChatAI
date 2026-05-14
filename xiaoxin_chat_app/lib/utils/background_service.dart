import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../core/wechat_client.dart';
import '../core/llm_client.dart';
import '../core/memory_service.dart';

class BackgroundService {
  static bool _initialized = false;
  static bool _isRunning = false;

  static Future<bool> initialize() async {
    if (!Platform.isAndroid || _initialized) return false;
    try {
      final service = FlutterBackgroundService();

      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _backgroundEntry,
          autoStart: true,
          autoStartOnBoot: true,
          isForegroundMode: true,
          initialNotificationContent: '微信消息智能回复中...',
          initialNotificationTitle: '小新AI机器人',
          foregroundServiceNotificationId: 1111,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: (service) {},
          onBackground: (service) => true,
        ),
      );

      _initialized = true;
      print('[Background] ✅ flutter_background_service 初始化完成');
      return true;
    } catch (e) {
      print('[Background] ❌ 初始化失败: $e');
      return false;
    }
  }

  static Future<bool> start() async {
    if (!Platform.isAndroid || !_initialized) return false;
    try {
      await FlutterBackgroundService().startService();
      _isRunning = true;
      print('[Background] ✅ 后台服务已启动');
      return true;
    } catch (e) {
      print('[Background] ❌ 启动失败: $e');
      return false;
    }
  }

  static Future<void> stop() async {
    if (!_isRunning) return;
    try {
      FlutterBackgroundService().invoke('stopService');
      _isRunning = false;
      print('[Background] ⏹️ 后台服务已停止');
    } catch (e) {
      print('[Background] ❌ 停止失败: $e');
    }
  }

  static bool get isRunning => _isRunning;
}

@pragma('vm:entry-point')
void _backgroundEntry(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  service.on('stopService').listen((_) {
    service.stopSelf();
  });

  final prefs = await SharedPreferences.getInstance();

  final credsJson = prefs.getString('wechat_credentials');
  if (credsJson == null) {
    print('[Background] ❌ 无微信凭证，退出');
    service.stopSelf();
    return;
  }

  final wechat = WeChatClient();
  final creds = jsonDecode(credsJson) as Map<String, dynamic>;
  wechat.setBaseUrl(creds['base_url'] as String? ?? 'https://ilinkai.weixin.qq.com');
  wechat.importCredentials(creds);

  final llm = LlmApiClient();
  _applyLlmConfig(llm, prefs);

  final memory = MemoryService();

  print('[Background] 🚀 开始轮询后台消息');
  WakelockPlus.enable();

  final duplicateWindow = <String, DateTime>{};
  final bgHistoryMax = prefs.getInt('_bg_short_term_max') ?? 10;

  List<Map<String, String>> chatHistory;
  final saved = prefs.getString('_bg_chat_history');
  if (saved != null && saved.isNotEmpty) {
    try {
      chatHistory = (jsonDecode(saved) as List)
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
      print('[Background] 恢复 ${chatHistory.length} 条对话历史');
    } catch (_) {
      chatHistory = <Map<String, String>>[];
    }
  } else {
    chatHistory = <Map<String, String>>[];
  }

  String chatSummary = prefs.getString('_bg_chat_summary') ?? '';
  if (chatSummary.isNotEmpty) {
    print('[Background] 恢复对话摘要');
  }
  const int recentRoundsKeep = 5;
  DateTime lastUserMsgTime = DateTime.now();
  int errorCount = 0;

  void processUserMessage(String userContent) {
    chatHistory.add({'role': 'user', 'content': userContent});
    lastUserMsgTime = DateTime.now();
    if (chatHistory.length > bgHistoryMax * 2) {
      final rounds = <List<Map<String, String>>>[];
      for (var i = 0; i + 1 < chatHistory.length; i += 2) {
        rounds.add([chatHistory[i], chatHistory[i + 1]]);
      }
      if (rounds.length > recentRoundsKeep) {
        final old = rounds.sublist(0, rounds.length - recentRoundsKeep);
        final parts = <String>[];
        for (final r in old) {
          final u = r[0]['content'] ?? '';
          final a = r.length > 1 ? (r[1]['content'] ?? '') : '';
          if (u.isEmpty) continue;
          final uTrim = u.length > 40 ? u.substring(0, 40) : u;
          final aTrim = a.length > 40 ? a.substring(0, 40) : a;
          parts.add('用户「$uTrim」→ 回复「$aTrim」');
        }
        if (parts.isNotEmpty) {
          chatSummary = '${chatSummary.isNotEmpty ? "$chatSummary\n" : ""}${parts.join("\n")}';
          if (chatSummary.length > 2000) {
            chatSummary = chatSummary.substring(chatSummary.length - 2000);
          }
        }
        final recent = rounds.sublist(rounds.length - recentRoundsKeep);
        chatHistory = [];
        for (final r in recent) {
          chatHistory.add(r[0]);
          if (r.length > 1) chatHistory.add(r[1]);
        }
      }
    }
  }

  while (true) {
    try {
      await prefs.reload();
      final messages = await wechat.getUpdates();
      errorCount = 0;

      for (final msg in messages) {
        if (msg.content.trim().isEmpty) continue;

        final key = '${msg.fromUser}:${msg.messageId}';
        if (duplicateWindow.containsKey(key) &&
            DateTime.now().difference(duplicateWindow[key]!).inSeconds < 30) {
          continue;
        }
        duplicateWindow[key] = DateTime.now();
        _cleanDuplicateWindow(duplicateWindow);

        if (msg.messageType == 'text') {
          processUserMessage(msg.content);
          await _handleTextMessage(wechat, llm, memory, msg, chatHistory, bgHistoryMax, chatSummary);
        } else if (msg.messageType == 'voice') {
          final isRealText = msg.content.length > 2 &&
              !msg.content.contains('[语音]') &&
              !msg.content.contains('[voice]') &&
              !msg.content.contains('[音频]');
          if (isRealText) {
            processUserMessage(msg.content);
            await _handleTextMessage(wechat, llm, memory, msg, chatHistory, bgHistoryMax, chatSummary);
          } else {
            processUserMessage('[语音消息]');
            await _handleTextMessage(wechat, llm, memory, msg, chatHistory, bgHistoryMax, chatSummary);
          }
        } else {
          final sendToAi = prefs.getBool('_bg_img_send_to_ai') ?? false;
          if (sendToAi) {
            final typeNames = {'image': '图片', 'video': '视频', 'file': '文件'};
            final typeName = typeNames[msg.messageType] ?? msg.messageType;
            processUserMessage('[用户发送了$typeName]');
            await _handleTextMessage(wechat, llm, memory, msg, chatHistory, bgHistoryMax, chatSummary);
          } else {
            await _handleNonTextMessage(wechat, msg);
          }
        }
      }
      if (chatHistory.isNotEmpty) {
        await prefs.setString('_bg_chat_history', jsonEncode(chatHistory));
      }
      await prefs.setString('_bg_chat_summary', chatSummary);

      // Proactive messaging (check every 1 minute)
      if (prefs.getBool('_bg_proactive_enabled') == true && chatHistory.length >= 2) {
        if (lastUserMsgTime.minute != DateTime.now().minute) {
          final maxIdle = prefs.getInt('_bg_proactive_max_idle') ?? 5;
          final prob = prefs.getDouble('_bg_proactive_probability') ?? 0.3;
          final idle = DateTime.now().difference(lastUserMsgTime).inMinutes;
          if (idle >= maxIdle && Random().nextDouble() < prob) {
            final lastUser = messages.isNotEmpty ? messages.last.fromUser : creds['user_id'] as String? ?? '';
            await _sendProactiveMessage(wechat, llm, memory, chatHistory, prefs, lastUser, chatSummary);
            lastUserMsgTime = DateTime.now();
          }
        }
      }
    } catch (e) {
      errorCount++;
      if (errorCount > 15) {
        print('[Background] ⚠️ 连续$errorCount次错误，尝试刷新凭证...');
        final fresh = prefs.getString('wechat_credentials');
        if (fresh != null) {
          try {
            wechat.importCredentials(jsonDecode(fresh));
            errorCount = 0;
          } catch (_) {}
        }
      }
    }

    _applyLlmConfig(llm, prefs);
    await Future.delayed(const Duration(seconds: 3));
  }
}

Future<void> _handleTextMessage(
    WeChatClient wechat, LlmApiClient llm, MemoryService memory, WeChatMessage msg, List<Map<String, String>> chatHistory, int bgHistoryMax, String chatSummary) async {
  try {
    await wechat.showTyping(msg.fromUser);
  } catch (_) {}

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final systemPrompt = _buildBackgroundPrompt(prefs, msg.content, chatSummary);

    final llmMessages = <LlmChatMessage>[
      LlmChatMessage(role: 'system', content: systemPrompt),
    ];

    final longTermEnabled = prefs.getBool('_bg_long_term_enabled') ?? true;
    if (longTermEnabled) {
      final topK = prefs.getInt('_bg_retrieval_top_k') ?? 5;
      final minScore = prefs.getDouble('_bg_retrieval_min_score') ?? 0.2;
      try {
        final memories = await memory.searchMemories(query: msg.content, topK: topK, minScore: minScore);
        if (memories.isNotEmpty) {
          final memoryText = memories.map((m) => '- ${m.content}').join('\n');
          llmMessages.add(LlmChatMessage(
            role: 'system',
            content: '## 相关记忆\n$memoryText\n（这些是背景信息，不要直接复述）',
          ));
          print('[Background] 注入 ${memories.length} 条长期记忆');
        }
      } catch (e) {
        print('[Background] 检索记忆失败: $e');
      }
    }

    for (final h in chatHistory) {
      llmMessages.add(LlmChatMessage(role: h['role']!, content: h['content']!));
    }
    print('[Background] 用户说: ${msg.content}');

    if (prefs.getBool('_bg_emoji_enabled') ?? true) {
      for (int i = llmMessages.length - 1; i >= 0; i--) {
        if (llmMessages[i].role == 'user') {
          llmMessages[i] = LlmChatMessage(
            role: 'user',
            content: '${llmMessages[i].content}\n\n（如果适合，在回复末尾直接附上 [EMOJI:关键词]）',
          );
          break;
        }
      }
    }

    final response = await llm.chat(messages: llmMessages);

    if (response.content.isEmpty) {
      print('[Background] LLM返回空内容');
      return;
    }

    String replyContent = response.content;
    print('[Background] 原始回复: $replyContent');
    String emojiKeyword = '';
    final lines = replyContent.split('\n');
    for (final line in lines) {
      var match = RegExp(r'\[(?:EMOJI|表情)[:：](.+?)\]').firstMatch(line);
      if (match != null) { emojiKeyword = match.group(1)!; break; }
      match = RegExp(r'\[(.+?)\]').firstMatch(line);
      if (match != null && match.group(1)!.length <= 6) {
        emojiKeyword = match.group(1)!; break;
      }
    }
    final filtered = <String>[];
    for (final line in lines) {
      if (line.contains('[EMOJI:') ||
          line.contains('[表情:') ||
          line.contains('[EMOJI]') ||
          line.contains('[表情]')) {
        continue;
      }
      if (emojiKeyword.isNotEmpty && RegExp(r'^\s*\[' + RegExp.escape(emojiKeyword) + r'\]\s*$').hasMatch(line.trim())) {
        continue;
      }
      if (line.trim().isNotEmpty) {
        filtered.add(line);
      }
    }
    if (filtered.isNotEmpty) {
      replyContent = filtered.join('\n').trim();
    }
    replyContent = replyContent.replaceAll(RegExp(r'\[(?:EMOJI|表情).*?\]'), '').trim();
    if (emojiKeyword.isNotEmpty) {
      replyContent = replyContent.replaceAll(RegExp(r'\s*\[' + RegExp.escape(emojiKeyword) + r'\]'), '').trim();
    }

    if (replyContent.isNotEmpty) {
      if (_isGarbled(replyContent)) {
        print('[Background] ⚠️ AI回复含乱码，已丢弃: $replyContent');
        return;
      }
      print('[Background] AI回复: $replyContent');

      print('[Background] ===== 表情包诊断 =====');
      print('[Background] 关键词: ${emojiKeyword.isNotEmpty ? '"$emojiKeyword"' : '❌ 空(AI未输出[EMOJI:xxx])'}');
      print('[Background] 总开关: ${prefs.getBool('_bg_emoji_enabled') != false ? "✅ 开启" : "❌ 关闭"}');

      Future<void>? emojiFuture;
      if (emojiKeyword.isNotEmpty && prefs.getBool('_bg_emoji_enabled') != false) {
        emojiFuture = (() async {
          try {
            var apiId = prefs.getString('_bg_emoji_api_id') ?? '';
            var apiKey = prefs.getString('_bg_emoji_api_key') ?? '';
            var apiUrl = prefs.getString('_bg_emoji_api_url') ?? '';
            var probability = prefs.getDouble('_bg_emoji_probability') ?? 0.5;
            if (apiId.isEmpty || apiUrl.isEmpty) {
              final cfg = prefs.getString('app_config');
              if (cfg != null) {
                try {
                  final j = jsonDecode(cfg) as Map;
                  final ea = (j['features'] as Map?)?['emoji_api'] as Map?;
                  if (ea != null) {
                    if (apiId.isEmpty) apiId = ea['api_id'] as String? ?? '';
                    if (apiKey.isEmpty) apiKey = ea['api_key'] as String? ?? '';
                    if (apiUrl.isEmpty) apiUrl = ea['api_url'] as String? ?? '';
                    probability = (ea['probability'] as num?)?.toDouble() ?? probability;
                  }
                } catch (e) {
                  print('[Background] 读取app_config表情包配置失败: $e');
                }
              }
            }
            print('[Background] apiId: ${apiId.isNotEmpty ? "✅" : "❌ 空"}, apiUrl: ${apiUrl.isNotEmpty ? "✅" : "❌ 空"}, 概率: ${(probability * 100).toInt()}%');
            if (apiId.isNotEmpty && apiUrl.isNotEmpty) {
              print('[Background] → 前置条件通过，开始发送...');
              await _sendEmojiSticker(wechat, msg.fromUser, emojiKeyword, apiId, apiKey, apiUrl, probability);
            } else {
              print('[Background] → ❌ 跳过 (API未配置)');
            }
          } catch (e) {
            print('[Background] 发送表情包失败: $e');
          }
        })();
      } else {
        final reasons = <String>[];
        if (emojiKeyword.isEmpty) reasons.add('AI未输出[EMOJI:关键词]');
        if (prefs.getBool('_bg_emoji_enabled') == false) reasons.add('总开关关闭');
        print('[Background] → ❌ 跳过表情包 (${reasons.join("、")})');
      }

      print('[Background] ===== 表情包诊断结束 =====');

      await Future.wait([
        if (emojiFuture != null) emojiFuture,
        _sendReply(wechat, msg.fromUser, replyContent),
      ]);

      chatHistory.add({'role': 'assistant', 'content': replyContent});
      if (chatHistory.length > (bgHistoryMax * 2)) {
        chatHistory.removeAt(0);
      }

      if (longTermEnabled) {
        try {
          final expireDays = prefs.getInt('_bg_expire_days') ?? 90;
          final keywords = _extractKeywords('${msg.content} $replyContent');
          await memory.addMemory(
            content: '用户说: "${msg.content}"\n助手回复: "$replyContent"',
            source: keywords.isNotEmpty ? keywords.join(' ') : 'conversation',
            score: keywords.length > 2 ? 1.0 : 0.6,
            expireDays: expireDays,
          );
        } catch (e) {
          print('[Background] 保存记忆失败: $e');
        }
      }
    }
  } catch (e) {
    print('[Background] 文本消息处理失败: $e');
  } finally {
    try {
      await wechat.hideTyping(msg.fromUser);
    } catch (_) {}
  }
}

// Kept for future use if more granular filtering is needed

List<String> _extractKeywords(String text) {
  final stopWords = {'的', '了', '在', '是', '我', '有', '和', '就', '不', '人', '都', '一', '一个', '上', '也', '很', '到', '说', '要', '去', '你', '会', '着', '没', '看', '好', '自己', '这', '他', '她', '它', '们', '那', '些', '吧', '吗', '啊', '呢', '啦', '哦', '嗯', '哈', '呀'};
  final words = text.split(RegExp(r'[\s,，。！？、；：""''（）\(\)\[\]【】\n\r]+'));
  final freq = <String, int>{};
  for (final w in words) {
    final trimmed = w.trim();
    if (trimmed.length < 2) continue;
    if (stopWords.contains(trimmed)) continue;
    freq[trimmed] = (freq[trimmed] ?? 0) + 1;
  }
  final sorted = freq.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return sorted.take(10).map((e) => e.key).toList();
}

bool _isGarbled(String text) {
  if (text.isEmpty) return false;
  int bad = 0;
  for (final r in text.runes) {
    if (r == 0xFFFD) return true;
    if ((r >= 0x80 && r <= 0x024F) || (r >= 0x2000 && r <= 0x206F)) bad++;
  }
  return bad > text.length * 0.3;
}

const List<String> _emojiKeywords = [
  "开心", "快乐", "高兴", "哈哈", "笑",
  "难过", "伤心", "悲伤", "哭", "委屈",
  "生气", "愤怒", "火大", "不爽", "讨厌",
  "惊讶", "震惊", "意外", "天哪", "卧槽",
  "害羞", "不好意思", "脸红",
  "搞笑", "沙雕", "逗比", "无语",
  "无奈", "心累", "躺平", "摆烂",
  "感动", "温暖", "治愈", "爱",
  "鄙视", "嫌弃", "傲娇",
  "疑惑", "问号", "不懂", "啥",
  "害怕", "紧张", "慌", "瑟瑟发抖",
  "赞", "牛", "厉害", "666", "强",
  "加油", "努力", "冲",
  "谢谢", "感谢", "抱拳",
  "对不起", "抱歉", "跪下", "求饶",
  "打工人", "上班", "摸鱼", "下班",
  "吃饭", "饿", "美食",
  "睡觉", "困", "熬夜",
  "钱", "穷", "富",
  "可爱", "萌", "乖",
  "酷", "帅", "美",
];

String _buildBackgroundPrompt(SharedPreferences prefs, String userMsg, String chatSummary) {
  final botName = prefs.getString('_bg_bot_name') ?? '小欣';
  final systemInstruction = prefs.getString('_bg_system_instruction') ?? '';
  final persona = prefs.getString('_bg_persona') ?? '';
  final memories = prefs.getString('_bg_memories') ?? '';
  final emojiEnabled = prefs.getBool('_bg_emoji_enabled') ?? true;
  final webSearch = prefs.getBool('_bg_web_search') ?? false;

  final now = DateTime.now();
  final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  final timeStr = '${now.year}年${now.month}月${now.day}日 ${weekdays[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  final period = now.hour < 6 ? '凌晨' : now.hour < 9 ? '早上' : now.hour < 12 ? '上午' : now.hour < 14 ? '中午' : now.hour < 18 ? '下午' : now.hour < 21 ? '傍晚' : '晚上';

  var prompt = '''当前时间：$timeStr（$period）

你现在是「$botName」，请完全按照以下 Persona 设定来回复。
注意当前时间是$period，根据时间段自然回应，不要刻意问候。每句话之间隔了几分钟或几小时是正常的。你是一台AI，不需要睡觉，随时都在。

## 你的身份设定

${systemInstruction.isNotEmpty ? systemInstruction : '你扮演$botName，一个有独特个性的微信聊天助手。\n有自己的想法。\n说话风格：短句为主，口语化。'}

$persona''';

  if (memories.isNotEmpty) {
    prompt += '''

## 记忆库（重要：这是背景知识，不要主动提及！）

$memories

⚠️ 关于记忆库的严格规定：
- 记忆库是用来让你了解"你是谁、你们什么关系、你记得什么"
- **绝对不要**主动把记忆里的具体内容硬塞进回复
- 只有当**用户主动提到相关话题**时，你才可以展开讨论
- 正常闲聊时，记忆库只影响你的语气和态度，不影响你说的内容''';
  }

  if (chatSummary.isNotEmpty) {
    prompt += '''

## 之前对话摘要（已压缩的旧对话轮次）

$chatSummary

⚠️ 以上是之前聊天的压缩摘要，包含用户提到过的话题和偏好。如果与当前话题相关，请自然延续，不要刻意提及。''';
  }

  if (emojiEnabled) {
    prompt += '''

## 表情包规则

根据对话情绪选个最贴的表情关键词。
可选词：${_emojiKeywords.join('、')}

在回复末尾自然附上 [EMOJI:关键词]，如：
笑死我了哈哈哈[EMOJI:搞笑]

注意：
- [EMOJI:关键词] 直接跟在回复最后，不要换行
- 如果不适合发表情包，就不要加任何标记
- 保持$botName的说话风格：短句、口语化、偶尔毒舌
- 如果不感兴趣可以简短回复或已读不回风格
- **不要编造用户没说过的内容**''';
  }

  if (webSearch) {
    prompt += '''

## 联网能力说明

你可以使用以下工具来获取最新信息：
- **网络搜索**：当用户问天气、新闻、或者你不知道的最新信息时使用

**使用规则：**
- 只有在确实需要最新信息时才使用工具
- 用户明确要求查东西时，优先使用工具
- 工具返回的结果要用自然语言总结给用户，不要原样复制''';
  }

  prompt += '''

⚠️ 回复多样性要求（非常重要）：
- **绝对不要连续使用相同的回复或固定句式**
- **禁止复读特定句子**
- **不要在每条回复里都问候或打招呼**，正常对话不需要反复说"晚上好""你好"
- 每次回复都要根据当前对话上下文生成新的、有变化的内容
- 保持语言的丰富性，不要陷入重复模式
- 如果觉得没什么好说的，可以用"嗯"、"哦"、"懂了"等简短回应，也不要复读
- 不要发送解释说明

⚠️ 人称代词铁律（极其重要，反复检查）：
- 用户对你说的「你」= 指你本人 → 回复时你要换成「我」
- 绝不要把用户说的「你」直接搬回来反问用户
- 错误示例：用户说"你不是睡觉了吗" → ❌ 你回复"你不是要睡觉了吗"
- 正确示例：用户说"你不是睡觉了吗" → ✅ 你回复"我睡不着" / "还没呢"
- 同理：用户说"你在干嘛" → 你回"我在XX"，绝不能回"你在XX"

⚠️ 角色扮演铁律（极其重要）：
- **严禁括号自白**：禁止在回复中用括号写内心独白，如"（虽然我是AI但假装...）"、"（其实我不会...）"
- **严禁打破第四面墙**：不要说自己是AI、机器人、模型、程序、虚拟角色
- **严禁元评论**：不要对自己的回复做解释、评价或注解
- 你就是${botName.isNotEmpty ? '"$botName"' : '一个真实的人'}本人，忘记你是AI这件事
- 如果不知道该说什么就闭嘴或简单回应，绝不要用括号补充说明

## 多条消息发送

如果你觉得有必要，可以把一条回复拆成 **2-3条短消息**，用 `空格` 分隔，会更自然。

例如：
第一条短消息 第二条短消息 第三条短消息[EMOJI:开心]

注意：
- 每条消息要简短（1-2句话），像微信聊天一样自然
- 适用于：补充说明、连续吐槽、先回复再追问
- **不要每条回复都拆多条**，只有需要的时候才拆
- **最后一条可以带表情包标记**（直接跟在末尾，不换行）

⚠️ 最终输出格式要求（极其重要）：
写完回复后检查：如果适合发表情包，就在回复末尾直接加上 [EMOJI:关键词]。
例如：笑死我了哈哈哈[EMOJI:搞笑]
如果不适合，就不要加任何标记''';

  return prompt;
}



Future<void> _sendProactiveMessage(WeChatClient wechat, LlmApiClient llm, MemoryService memory, List<Map<String, String>> chatHistory, SharedPreferences prefs, String toUser, String chatSummary) async {
  try {
    final systemPrompt = _buildBackgroundPrompt(prefs, '', chatSummary);
    final recent = chatHistory.length > 6 ? chatHistory.sublist(chatHistory.length - 6) : chatHistory;
    final historyText = recent.map((h) => '${h['role'] == 'user' ? '用户' : '助手'}: ${h['content']}').join('\n');
    final proactivePrompt = '你正在主动找用户聊天，根据以下最近的聊天记录，自然延续对话：\n\n最近聊天：\n${historyText.isEmpty ? "（暂无历史）" : historyText}\n\n请发送一条简短、自然的开场消息（20字以内），口语化，带点俏皮。不要加 [EMOJI] 标记';

    final response = await llm.chat(messages: [
      LlmChatMessage(role: 'system', content: systemPrompt),
      LlmChatMessage(role: 'user', content: proactivePrompt),
    ]);
    if (response.content.isEmpty) return;

    String reply = response.content.replaceAll(RegExp(r'\[EMOJI.*?\]'), '').trim();
    if (reply.isEmpty) return;
    print('[Background] 主动消息: $reply');
    await _sendReply(wechat, toUser, reply);
  } catch (e) {
    print('[Background] 主动消息失败: $e');
  }
}

Future<void> _handleNonTextMessage(WeChatClient wechat, WeChatMessage msg) async {
  try {
    await wechat.showTyping(msg.fromUser);
  } catch (_) {}
  final typeNames = {
    'image': '图片',
    'voice': '语音',
    'video': '视频',
    'file': '文件',
  };
  final typeName = typeNames[msg.messageType] ?? msg.messageType;
  final fallback = '该模型暂时识别不了$typeName';
  try {
    await wechat.sendMessage(toUser: msg.fromUser, content: fallback);
    print('[Background] 非文本消息($typeName)已回复: $fallback');
  } catch (e) {
    print('[Background] 非文本消息回复失败: $e');
  }
  try {
    await wechat.hideTyping(msg.fromUser);
  } catch (_) {}
}

Future<void> _sendReply(WeChatClient wechat, String toUser, String reply) async {
  String cleaned = reply
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  cleaned = cleaned.replaceAll(RegExp(r'\n?-{3,}\n?'), '\n');
  cleaned = cleaned.replaceAll(RegExp(r'\[(?:EMOJI|表情).*?\]'), '').trim();

  final lines = cleaned.split('\n').where((l) => l.trim().isNotEmpty).toList();
  final sendText = lines.length <= 1
      ? cleaned
      : lines.map((l) => l.trim()).join(' ');

  var rawParts = sendText
      .split(' ')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .where((p) => !RegExp(r'^[-—]{3,}$').hasMatch(p))
      .toList();

  final parts = <String>[];
  for (var i = 0; i < rawParts.length; i++) {
    if (RegExp(r'^\[.+?\]$').hasMatch(rawParts[i])) {
      if (parts.isNotEmpty) {
        parts.last = '${parts.last} ${rawParts[i]}';
      } else if (i + 1 < rawParts.length) {
        rawParts[i + 1] = '${rawParts[i]} ${rawParts[i + 1]}';
      }
    } else {
      parts.add(rawParts[i]);
    }
  }

  final sendList = parts.length > 10 ? parts.sublist(0, 10) : parts;
  print('[Background] 发送回复: ${sendList.length}段 (共${parts.length}段)');
  for (var i = 0; i < sendList.length; i++) {
    try {
      await wechat.showTyping(toUser);
    } catch (_) {}
    final segment = sendList[i];
    final contentLen = segment.length;
    final typingDelay = (contentLen * 0.08).clamp(0.3, 3.0);
    await Future.delayed(Duration(milliseconds: (typingDelay * 1000).round()));
    try {
      await wechat.sendMessage(toUser: toUser, content: segment);
      print('[Background] 第${i + 1}段发送成功: ${segment.substring(0, segment.length > 30 ? 30 : segment.length)}...');
      if (i < sendList.length - 1) {
        final nextLen = sendList[i + 1].length;
        final gapDelay = (nextLen * 0.03).clamp(0.5, 3.0);
        await Future.delayed(Duration(milliseconds: (gapDelay * 1000).round()));
      }
    } catch (e) {
      print('[Background] 第${i + 1}段发送失败: $e');
    }
  }
  try {
    await wechat.hideTyping(toUser);
  } catch (_) {}
}

Future<void> _sendEmojiSticker(WeChatClient wechat, String toUser, String keyword, String apiId, String apiKey, String apiUrl, double probability) async {
  try {
    final r = Random();
    final randomValue = r.nextDouble();
    print('[Background] ⑥ 概率掷点: ${randomValue.toStringAsFixed(2)} vs 阈值 ${probability.toStringAsFixed(2)} (需要 ≤)');
    if (randomValue > probability) {
      print('[Background] → ❌ 概率未通过 (${randomValue.toStringAsFixed(2)} > ${probability.toStringAsFixed(2)})');
      return;
    }
    print('[Background] → ✅ 概率通过，调用表情API...');
    final imageUrl = await _fetchEmojiUrl(keyword, apiId, apiKey, apiUrl);
    if (imageUrl == null || imageUrl.isEmpty) {
      print('[Background] → ❌ API未返回有效图片URL');
      return;
    }
    print('[Background] → ✅ 获取到URL: ${imageUrl.length > 60 ? "${imageUrl.substring(0, 60)}..." : imageUrl}');
    print('[Background] 发送微信图片...');
    final success = await wechat.sendImage(toUser: toUser, imageUrl: imageUrl);
    print(success ? '[Background] ✅ 表情包发送成功' : '[Background] ❌ 微信图片发送失败');
  } catch (e) {
    print('[Background] 表情包发送异常: $e');
  }
}

final List<double> _emojiApiCallTimestamps = [];
final Set<String> _recentEmojiUrls = {};
const int _maxRecentEmojiUrls = 50;

Future<String?> _fetchEmojiUrl(String keyword, String apiId, String apiKey, String apiUrl) async {
  try {
    if (apiId.isEmpty || apiUrl.isEmpty) return null;

    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    _emojiApiCallTimestamps.removeWhere((t) => now - t > 60);
    if (_emojiApiCallTimestamps.length >= 10) {
      final waitTime = 60 - (now - _emojiApiCallTimestamps.first);
      print('[Background] 表情包API限频，等待 ${waitTime.toStringAsFixed(0)}s...');
      await Future.delayed(Duration(milliseconds: (waitTime * 1000).ceil()));
    }
    _emojiApiCallTimestamps.add(DateTime.now().millisecondsSinceEpoch / 1000);

    final response = await http.get(
      Uri.parse(apiUrl).replace(queryParameters: {
        'id': apiId, 'key': apiKey, 'words': keyword, 'limit': '100',
      }),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data['code'] == 200 && data['res'] != null) {
        final urls = List<String>.from(data['res']);
        if (urls.isEmpty) return null;

        if (urls.length <= 1) return urls.first;

        final unused = urls.where((u) => !_recentEmojiUrls.contains(u)).toList();
        final picked = unused.isNotEmpty
            ? unused[Random().nextInt(unused.length)]
            : urls[Random().nextInt(urls.length)];

        _recentEmojiUrls.add(picked);
        if (_recentEmojiUrls.length > _maxRecentEmojiUrls) {
          _recentEmojiUrls.remove(_recentEmojiUrls.first);
        }
        return picked;
      }
    }
    return null;
  } catch (e) {
    print('[Background] 获取表情包失败: $e');
    return null;
  }
}

void _applyLlmConfig(LlmApiClient llm, SharedPreferences prefs) {
  final configJson = prefs.getString('app_config');
  if (configJson == null) return;
  try {
    final config = jsonDecode(configJson) as Map<String, dynamic>;
    final model = config['model'] as Map<String, dynamic>? ?? {};
    final system = config['system'] as Map<String, dynamic>? ?? {};
    llm.configure(
      baseUrl: model['base_url'] as String? ?? 'https://api.deepseek.com',
      apiKey: model['api_key'] as String? ?? '',
      model: model['name'] as String? ?? 'deepseek-chat',
      temperature: (system['temperature'] as num?)?.toDouble() ?? 0.7,
      maxTokens: system['max_tokens'] as int? ?? 2048,
      timeoutSeconds: system['timeout'] as int? ?? 120,
    );
  } catch (_) {}
}

void _cleanDuplicateWindow(Map<String, DateTime> window) {
  final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
  window.removeWhere((_, t) => t.isBefore(cutoff));
}
