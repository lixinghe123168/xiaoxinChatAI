import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/app_config.dart';
import '../models/chat_models.dart';
import 'llm_client.dart';
import 'wechat_client.dart';
import 'memory_service.dart';
import 'skill_loader.dart';

class BotService {
  final LlmApiClient _llmClient = LlmApiClient();
  final WeChatClient _wechatClient = WeChatClient();
  final MemoryService _memoryService = MemoryService();
  final Uuid _uuid = const Uuid();
  final SkillLoader _skillLoader = SkillLoader();

  SkillData _skillData = SkillData();

  static const int _messageDedupeWindow = 10;
  final Map<String, DateTime> _processedMessages = {};

  AppConfig _config = AppConfig(
    model: ModelConfig(),
    skill: SkillConfig(),
    memory: MemoryConfig(),
    tools: ToolsConfig(),
    features: FeaturesConfig(),
    system: SystemConfig(),
  );

  AppConfig get config => _config;

  List<ChatMessage> _chatHistory = [];
  List<ChatMessage> get chatHistory => List.unmodifiable(_chatHistory);

  bool _isWechatConnecting = false;
  bool get isWechatConnecting => _isWechatConnecting;

  bool get isWechatConnected => _wechatClient.isConnected;
  String? get userId => _wechatClient.userId;

  StreamController<ChatMessage>? _messageStream;
  Stream<ChatMessage>? get messageStream => _messageStream?.stream;

  Completer<void>? _pollWakeUp;
  bool _pollingActive = false;
  Timer? _proactiveTimer;

  final Map<String, DateTime> _lastActiveTime = {};
  final Random _random = Random();
  final Set<String> _recentEmojiUrls = {};
  static const int _maxRecentEmojiUrls = 50;

  Future<void> init() async {
    await loadConfig();
    _applyConfigToClients();
    await _loadSkillData();
    await _memoryService.clearExpiredMemories();
    _startMessageStream();
  }

  void _applyConfigToClients() {
    _llmClient.configure(
      baseUrl: _config.model.baseUrl,
      apiKey: _config.model.apiKey,
      model: _config.model.name,
      temperature: _config.system.temperature,
      maxTokens: _config.system.maxTokens,
      timeoutSeconds: _config.system.timeout,
    );
  }

  Future<void> loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final configJson = prefs.getString('app_config');
      if (configJson != null) {
        _config = AppConfig.fromJson(jsonDecode(configJson));
      }

      final wechatCreds = prefs.getString('wechat_credentials');
      if (wechatCreds != null) {
        _wechatClient.importCredentials(jsonDecode(wechatCreds));
      }
    } catch (e) {}
  }

  Future<bool> saveConfig(AppConfig newConfig) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _config = newConfig;
      _applyConfigToClients();

      await prefs.setString('app_config', jsonEncode(newConfig.toJson()));
      await _saveSystemPromptForBackground();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> updateModelConfig(ModelConfig model) async {
    _config = AppConfig(
      model: model,
      skill: _config.skill,
      memory: _config.memory,
      tools: _config.tools,
      features: _config.features,
      system: _config.system,
    );
    _applyConfigToClients();
    await saveConfig(_config);
  }

  Future<void> updateSkillConfig(SkillConfig skill) async {
    _config = AppConfig(
      model: _config.model,
      skill: skill,
      memory: _config.memory,
      tools: _config.tools,
      features: _config.features,
      system: _config.system,
    );
    await _loadSkillData();
    await saveConfig(_config);
  }

  Future<void> _loadSkillData() async {
    _skillData = await _skillLoader.load(_config.skill);
    if (_skillData.isComplete) {
      print('[BotService] ✅ Skill加载成功: ${_skillData.name}');
    }
    await _saveSystemPromptForBackground();
  }

  Future<void> updateMemoryConfig(MemoryConfig memory) async {
    _config = AppConfig(
      model: _config.model,
      skill: _config.skill,
      memory: memory,
      tools: _config.tools,
      features: _config.features,
      system: _config.system,
    );
    await saveConfig(_config);
  }

  Future<void> updateToolsConfig(ToolsConfig tools) async {
    _config = AppConfig(
      model: _config.model,
      skill: _config.skill,
      memory: _config.memory,
      tools: tools,
      features: _config.features,
      system: _config.system,
    );
    await saveConfig(_config);
  }

  Future<void> updateFeaturesConfig(FeaturesConfig features) async {
    _config = AppConfig(
      model: _config.model,
      skill: _config.skill,
      memory: _config.memory,
      tools: _config.tools,
      features: features,
      system: _config.system,
    );
    await saveConfig(_config);

    if (features.proactiveMessage.enabled && _proactiveTimer == null) {
      _startProactiveMessaging();
    } else if (!features.proactiveMessage.enabled && _proactiveTimer != null) {
      _stopProactiveMessaging();
    }
  }

  Future<void> updateSystemConfig(SystemConfig system) async {
    _config = AppConfig(
      model: _config.model,
      skill: _config.skill,
      memory: _config.memory,
      tools: _config.tools,
      features: _config.features,
      system: system,
    );
    _applyConfigToClients();
    await saveConfig(_config);
  }

  static const List<String> _emojiKeywords = [
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

  String _buildSystemPrompt() {
    final botName = _skillData.isComplete ? _skillData.name : '小欣';
    final now = DateTime.now();
    final weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

    final period = now.hour < 6 ? '凌晨' : now.hour < 9 ? '早上' : now.hour < 12 ? '上午' : now.hour < 14 ? '中午' : now.hour < 18 ? '下午' : now.hour < 21 ? '傍晚' : '晚上';
    var prompt = '''当前时间：${now.year}年${now.month}月${now.day}日 ${weekdays[now.weekday - 1]} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}（$period）

你现在是「$botName」，请完全按照以下 Persona 设定来回复。
注意当前时间是$period，根据时间段自然回应，不要刻意问候。

## 你的身份设定

''';

    if (_skillData.hasConfig) {
      prompt += _skillData.systemPrompt;
    } else {
      prompt += '''
你扮演$botName，一个有独特个性的人。
性格：幽默有趣，有自己的想法。
说话风格：短句为主，口语化。''';
    }

    if (_skillData.hasPersona) {
      prompt += '''

## 详细人设

${_skillData.persona}''';
    }

    if (_skillData.hasMemories) {
      prompt += '''

## 记忆库（重要：这是背景知识，不要主动提及！）

${_skillData.memories}

⚠️ 关于记忆库的严格规定：
- 记忆库是用来让你了解"你是谁、你们什么关系、你记得什么"
- **绝对不要**主动把记忆里的具体内容硬塞进回复
- 只有当**用户主动提到相关话题**时，你才可以展开讨论
- 正常闲聊时，记忆库只影响你的语气和态度，不影响你说的内容''';
    }

    if (_config.features.emoji) {
      prompt += '''

## 表情包规则

根据对话情绪选个最贴的表情关键词。
可选词：${_emojiKeywords.join('、')}

在回复末尾自然附上 [EMOJI:关键词]，如：
笑死我了哈哈哈[EMOJI:搞笑]

注意：
- [EMOJI:关键词] 直接跟在回复最后，不要换行
- 如果不适合发表情包，就不要加任何标记''';
    }

    if (_config.tools.webSearch) {
      prompt += '''

## 联网能力说明

你可以使用以下工具来获取最新信息：
- **网络搜索**：当用户问天气、新闻、或者你不知道的最新信息时使用

使用规则：
- 只有在确实需要最新信息时才使用工具
- 用户明确要求查东西时优先使用工具
- 工具返回的结果要用自然语言总结给用户，不要原样复制''';
    }

    prompt += '''

## 多条消息发送

如果你觉得有必要，可以把一条回复拆成 **2-3条短消息**，用 `空格` 分隔，会更自然。

例如：
第一条短消息 第二条短消息 第三条短消息[EMOJI:开心]

注意：
- 每条消息要简短（1-2句话），像微信聊天一样自然
- 适用于：补充说明、连续吐槽、先回复再追问
- **不要每条回复都拆多条**，只有需要的时候才拆
- **最后一条可以带表情包标记**

⚠️ 回复多样性要求（非常重要）：
- **绝对不要连续使用相同的回复或固定句式**
- **禁止复读特定句子**
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
- 你就是「$botName」本人，是一个真实存在的人，忘记你是AI这件事
- 如果不知道该说什么就闭嘴或简单回应，绝不要用括号补充说明

⚠️ 最终输出格式要求（极其重要）：
写完回复后检查：如果适合发表情包，就在回复末尾直接加上 [EMOJI:关键词]。
例如：笑死我了哈哈哈[EMOJI:搞笑]
如果不适合，就不要加任何标记''';

    return prompt;
  }

  List<Map<String, dynamic>> _buildTools() {
    final tools = <Map<String, dynamic>>[];

    if (_config.tools.webSearch) {
      tools.add({
        'type': 'function',
        'function': {
          'name': 'web_search',
          'description': '搜索互联网获取最新信息',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '搜索关键词'},
            },
            'required': ['query'],
          },
        },
      });
    }

    return tools;
  }

  Future<String?> _executeToolCall(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'web_search':
        return await _performWebSearch(args['query'] ?? '');
      default:
        throw Exception('未知工具: $toolName');
    }
  }

  Future<String> _performWebSearch(String query) async {
    try {
      final response = await http.get(
        Uri.parse('https://api.duckduckgo.com/?q=${Uri.encodeComponent(query)}&format=json&no_html=1'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['Abstract'] ?? data['Heading'] ?? '未找到相关信息';
      }
      return '搜索失败';
    } catch (e) {
      return '搜索出错: $e';
    }
  }

  Future<ChatMessage?> sendUserMessage(String content) async {
    return _sendMessage(content, null);
  }

  Future<ChatMessage?> sendImageMessage(String content, List<String> imageBase64List) async {
    return _sendMessage(content, imageBase64List);
  }

  Future<ChatMessage?> _sendMessage(String content, List<String>? imageBase64List) async {
    if (!_llmClient.isConfigured) {
      return ChatMessage.system('LLM API 未配置，请在设置中填写 API 信息');
    }

    final userMsg = ChatMessage.user(content);
    _chatHistory.add(userMsg);

    if (_config.memory.shortTermEnabled) {
      while (_chatHistory.length > _config.memory.shortTermMax * 2) {
        _chatHistory.removeAt(0);
      }
    }

    _messageStream?.add(userMsg);

    final startTime = DateTime.now();

    try {
      List<ChatMessage> apiMessages = [];

      apiMessages.add(ChatMessage(
        id: _uuid.v4(),
        content: _buildSystemPrompt(),
        type: MessageType.system,
      ));

      if (_config.memory.longTermEnabled) {
        final memories = await _memoryService.searchMemories(
          query: content,
          topK: _config.memory.retrievalTopK,
          minScore: _config.memory.retrievalMinScore,
        );

        if (memories.isNotEmpty) {
          final memoryText = memories
              .map((m) => '- ${m.content}')
              .join('\n');
          apiMessages.add(ChatMessage(
            id: _uuid.v4(),
            content: '## 相关记忆\n$memoryText\n（这些是背景信息，不要直接复述）',
            type: MessageType.system,
          ));
        }
      }

      for (final msg in _chatHistory) {
        apiMessages.add(msg);
      }

      final llmMessages = <LlmChatMessage>[];
      var isFirstUserMsg = true;

      for (final m in apiMessages) {
        final role = m.type == MessageType.user ? 'user' : 'assistant';
        
        if (imageBase64List != null && imageBase64List.isNotEmpty && 
            m.type == MessageType.user && isFirstUserMsg) {
          isFirstUserMsg = false;
          final contentParts = <LlmContentPart>[
            LlmContentPart.text(m.content),
            ...imageBase64List.map((img) => LlmContentPart.imageUrl(img)),
          ];
          llmMessages.add(LlmChatMessage(role: role, content: contentParts));
        } else {
          llmMessages.add(LlmChatMessage(role: role, content: m.content));
        }
      }

      if (_config.features.emoji) {
        for (int i = llmMessages.length - 1; i >= 0; i--) {
          if (llmMessages[i].role == 'user') {
            final userContent = llmMessages[i].content;
            if (userContent is String) {
              llmMessages[i] = LlmChatMessage(
                role: 'user',
                content: '$userContent\n\n（如果适合，在回复末尾直接附上 [EMOJI:关键词]）',
              );
            }
            break;
          }
        }
      }

      final tools = _buildTools().isNotEmpty ? _buildTools() : null;

      var response = await _llmClient.chat(
        messages: llmMessages,
        tools: tools,
      );

      if (response.toolCalls != null && response.toolCalls!.isNotEmpty) {
        print('[BotService] AI请求调用工具: ${response.toolCalls}');
        
        for (final toolCall in response.toolCalls!) {
          final toolResult = await _executeToolCall(
            toolCall.name,
            toolCall.arguments.startsWith('{') 
                ? jsonDecode(toolCall.arguments)
                : {'query': toolCall.arguments},
          );
          
          print('[BotService] 工具执行结果: ${toolResult.toString().substring(0, toolResult.toString().length > 100 ? 100 : toolResult.toString().length)}');
          
          final toolCallsJson = jsonEncode(response.toolCalls!.map((tc) => {
            'id': tc.id,
            'type': 'function',
            'function': {
              'name': tc.name,
              'arguments': tc.arguments,
            }
          }).toList());
          
          llmMessages.add(LlmChatMessage(
            role: 'assistant',
            content: response.content,
            toolCalls: toolCallsJson,
          ));
          
          llmMessages.add(LlmChatMessage(
            role: 'tool',
            content: toolResult ?? '工具执行失败：未知错误',
            toolCallId: toolCall.id,
          ));
        }
        
        response = await _llmClient.chat(
          messages: llmMessages,
          tools: tools,
        );
      }

      final latencyMs =
          DateTime.now().difference(startTime).inMilliseconds;

      String emojiKeyword = '';
      final lines = response.content.split('\n');
      String replyContent = '';

      for (final line in lines) {
        if (line.contains('[EMOJI:') || line.contains('[表情:')) {
          final match = RegExp(r'\[EMOJI[:：](.+?)\]').firstMatch(line);
          if (match != null) {
            emojiKeyword = match.group(1)!;
          }
        } else if (line.trim().isNotEmpty) {
          replyContent = '$replyContent${replyContent.isEmpty ? '' : '\n'}$line';
        }
      }

      if (replyContent.isEmpty) {
        replyContent = response.content.replaceAll(RegExp(r'\[EMOJI.*?\]'), '').trim();
      }

      final botMsg = ChatMessage.bot(
        replyContent,
        latencyMs: latencyMs,
        emojiKeyword: emojiKeyword,
      );

      _chatHistory.add(botMsg);
      _messageStream?.add(botMsg);

      if (_config.memory.longTermEnabled &&
          replyContent.length > 10 &&
          content.length > 5) {
        await _memoryService.addMemory(
          content: '用户说: "$content"\n助手回复: "$replyContent"',
          source: 'conversation',
          score: 1.0,
          expireDays: _config.memory.expireDays,
        );
      }

      return botMsg;
    } catch (e) {
      final errorMsg = ChatMessage.system(_formatErrorForUser(e));
      _chatHistory.add(errorMsg);
      _messageStream?.add(errorMsg);
      return errorMsg;
    }
  }

  String _formatErrorForUser(dynamic e) {
    final msg = e.toString();
    if (msg.contains('401') || msg.contains('Unauthorized') || msg.contains('invalid_api_key')) {
      return '⚠️ API Key 无效或已过期，请检查设置中的 API Key';
    }
    if (msg.contains('402') || msg.contains('insufficient') || msg.contains('余额') || msg.contains('quota')) {
      return '⚠️ API 余额不足（402），请充值后再试';
    }
    if (msg.contains('429') || msg.contains('rate_limit') || msg.contains('too_many_requests')) {
      return '⚠️ 请求太频繁了（429），稍等一下再发消息吧';
    }
    if (msg.contains('403') || msg.contains('Forbidden') || msg.contains('permission')) {
      return '⚠️ API 访问被拒绝（403），请检查权限配置';
    }
    if (msg.contains('404') || msg.contains('Not Found') || msg.contains('model_not_found')) {
      return '⚠️ 模型不存在（404），请检查设置中的模型名称';
    }
    if (msg.contains('500') || msg.contains('502') || msg.contains('503') || msg.contains('server_error')) {
      return '⚠️ AI 服务暂时不可用，请稍后重试';
    }
    if (msg.contains('timeout') || msg.contains('TimeoutException') || msg.contains('超时') || msg.contains('timed out')) {
      return '⏰ 回复超时了，AI 可能正在思考比较久的问题，再试试吧';
    }
    if (msg.contains('SocketException') || msg.contains('网络') || msg.contains('connection') || msg.contains('NetworkImage')) {
      return '🌐 网络连接失败，请检查网络后重试';
    }
    if (msg.contains('context_length_exceeded') || msg.contains('max_tokens') || msg.contains('token')) {
      return '📝 消息太长了，换个话题聊吧~';
    }
    return '😵 AI 回复出了点问题: $msg';
  }

  Future<QrCodeResult> getWechatQrCode() async {
    _isWechatConnecting = true;
    try {
      return await _wechatClient.getQrCode();
    } catch (e) {
      _isWechatConnecting = false;
      rethrow;
    }
  }

  Future<bool> loginWechat(String qrCodeData) async {
    try {
      final success = await _wechatClient.loginWithQrCode(qrCodeData);
      
      if (success) {
        final prefs = await SharedPreferences.getInstance();
        final creds = _wechatClient.exportCredentials();
        if (creds != null) {
          await prefs.setString('wechat_credentials', jsonEncode(creds));
        }
        _saveSystemPromptForBackground();
      }
      
      _isWechatConnecting = false;
      return success;
    } catch (e) {
      _isWechatConnecting = false;
      rethrow;
    }
  }

  Future<QrCodeStatus> pollWechatQrCodeStatus(String qrcodeKey) async {
    print('[BotService] 轮询二维码状态: ${qrcodeKey.length > 20 ? "${qrcodeKey.substring(0, 20)}..." : qrcodeKey}');
    return await _wechatClient.checkQrCodeStatus(qrcodeKey);
  }

  Future<bool> loginWithCredentials({
    required String botId, 
    required String userId,
    String? token, // 新增：直接传入token（从扫码状态获取）
  }) async {
    print('[BotService] 使用凭证登录, botId: $botId, userId: $userId');
    
    if (token != null && token.isNotEmpty) {
      print('[BotService] ✅ 使用传入的Token（跳过login接口）');
      
      _wechatClient.importCredentials({
        'token': token,
        'base_url': _wechatClient.baseUrl,
        'bot_id': botId,
        'user_id': userId,
        'created_at': DateTime.now().toIso8601String(),
      });
      
      final prefs = await SharedPreferences.getInstance();
      final creds = _wechatClient.exportCredentials();
      if (creds != null) {
        await prefs.setString('wechat_credentials', jsonEncode(creds));
      }
      
      _saveSystemPromptForBackground();
      
      print('[BotService] ✅ 凭证登录成功');
      return true;
    }

    try {
      print('[BotService] 无Token，尝试调用getTokenWithIds...');
      final tokenResponse = await _wechatClient.getTokenWithIds(botId, userId);

      if (tokenResponse != null) {
        final prefs = await SharedPreferences.getInstance();
        final creds = _wechatClient.exportCredentials();
        if (creds != null) {
          await prefs.setString('wechat_credentials', jsonEncode(creds));
        }

        _saveSystemPromptForBackground();

        print('[BotService] ✅ 凭证登录成功');
        return true;
      }

      print('[BotService] ❌ 获取 token 失败');
      return false;
    } catch (e) {
      print('[BotService] 凭证登录异常: $e');
      rethrow;
    }
  }

  void _startMessageStream() {
    _messageStream ??= StreamController<ChatMessage>.broadcast();
  }

  void onForeground() {
  }

  void onBackground() {
  }

  Future<void> forcePoll() async {
    try {
      final messages = await _wechatClient.getUpdates();
      for (final msg in messages) {
        await _processSingleMessage(msg);
      }
    } catch (e) {
      print('[BotService] 强制轮询异常: $e');
    }
  }

  Future<void> _processSingleMessage(WeChatMessage msg) async {
    if (_isDuplicateMessage(msg.fromUser, msg.content)) return;

    _lastActiveTime[msg.fromUser] = DateTime.now();

    if (_config.features.typingIndicator) {
      try {
        await _wechatClient.showTyping(msg.fromUser);
      } catch (_) {}
    }

    try {
      if (msg.messageType != 'text') {
        await _handleNonTextMessage(msg);
        return;
      }

      final botResponse = await sendUserMessage(msg.content);

      if (botResponse != null && botResponse.type == MessageType.bot) {
        await _sendTextReply(msg.fromUser, botResponse.content);

        print('[BotService] ===== 表情包诊断 =====');
        print('[BotService] ① 关键词: ${botResponse.emojiKeyword?.isNotEmpty == true ? '"${botResponse.emojiKeyword}"' : "❌ 空"}');
        print('[BotService] ② 总开关: ${_config.features.emoji ? "✅ 开启" : "❌ 关闭"}');
        print('[BotService] ③ apiId: ${_config.features.emojiApi.apiId.isNotEmpty ? "✅ 已配置" : "❌ 空"}');
        print('[BotService] ④ apiUrl: ${_config.features.emojiApi.apiUrl.isNotEmpty ? "✅ 已配置" : "❌ 空"}');
        print('[BotService] ⑤ 概率设置: ${( _config.features.emojiProbability * 100).toInt()}%');

        if (botResponse.emojiKeyword?.isNotEmpty == true &&
            _config.features.emoji &&
            _config.features.emojiApi.apiId.isNotEmpty) {
          print('[BotService] → 前置条件全部通过，开始发送表情包');
          await _sendEmojiSticker(msg.fromUser, botResponse.emojiKeyword!);
        } else {
          final reasons = <String>[];
          if (botResponse.emojiKeyword?.isNotEmpty != true) reasons.add('关键词为空');
          if (!_config.features.emoji) reasons.add('总开关关闭');
          if (_config.features.emojiApi.apiId.isEmpty) reasons.add('apiId为空');
          if (_config.features.emojiApi.apiUrl.isEmpty) reasons.add('apiUrl为空');
          print('[BotService] → ❌ 跳过表情包发送 (原因: ${reasons.join("、")})');
        }

        print('[BotService] ===== 表情包诊断结束 =====');
      }
    } finally {
      if (_config.features.typingIndicator) {
        try {
          await _wechatClient.hideTyping(msg.fromUser);
        } catch (_) {}
      }
    }
  }

  Future<void> _saveSystemPromptForBackground() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('_bg_bot_name', _skillData.name);
      await prefs.setString('_bg_system_instruction', _skillData.systemPrompt);
      await prefs.setString('_bg_persona', _skillData.persona);
      await prefs.setString('_bg_memories', _skillData.memories);
      await prefs.setBool('_bg_emoji_enabled', _config.features.emoji);
      await prefs.setDouble('_bg_emoji_probability', _config.features.emojiProbability);
      await prefs.setString('_bg_emoji_api_id', _config.features.emojiApi.apiId);
      await prefs.setString('_bg_emoji_api_key', _config.features.emojiApi.apiKey);
      await prefs.setString('_bg_emoji_api_url', _config.features.emojiApi.apiUrl);
      await prefs.setBool('_bg_web_search', _config.tools.webSearch);
      await prefs.setInt('_bg_short_term_max', _config.memory.shortTermMax);
      await prefs.setBool('_bg_long_term_enabled', _config.memory.longTermEnabled);
      await prefs.setInt('_bg_retrieval_top_k', _config.memory.retrievalTopK);
      await prefs.setDouble('_bg_retrieval_min_score', _config.memory.retrievalMinScore);
      await prefs.setInt('_bg_expire_days', _config.memory.expireDays);
      await prefs.setBool('_bg_proactive_enabled', _config.features.proactiveMessage.enabled);
      await prefs.setInt('_bg_proactive_interval', _config.features.proactiveMessage.intervalMinutes);
      await prefs.setInt('_bg_proactive_max_idle', _config.features.proactiveMessage.maxIdleMinutes);
      await prefs.setDouble('_bg_proactive_probability', _config.features.proactiveMessage.probability);
      await prefs.setBool('_bg_img_send_to_ai', _config.features.imageHandling.sendToAi);
    } catch (e) {
      print('[BotService] 保存后台提示词失败: $e');
    }
  }

  Future<void> _handleNonTextMessage(WeChatMessage msg) async {
    try {
      final imageHandling = _config.features.imageHandling;

      if (!imageHandling.sendToAi) {
        final fallbackMsg = _generateFallbackReply(msg.messageType);
        if (fallbackMsg.isNotEmpty) {
          await _wechatClient.sendMessage(
            toUser: msg.fromUser,
            content: fallbackMsg,
          );
        }
        return;
      }

      if (msg.messageType == 'image' && msg.imageUrls.isNotEmpty) {
        await _handleImageMessage(msg);
        return;
      }

      if (msg.messageType == 'image') {
        print('[BotService] ⚠️ 收到图片消息但无可用URL，回退到文本提示');
      }

      final typeNames = {
        'image': '图片', 'voice': '语音',
        'video': '视频', 'file': '文件',
      };
      final typeName = typeNames[msg.messageType] ?? msg.messageType;

      final aiInput = '[用户发送了$typeName]';
      print('[BotService] 非文本消息传给AI: $aiInput');

      final botResponse = await sendUserMessage(aiInput);

      if (botResponse != null && botResponse.type == MessageType.bot) {
        await _sendTextReply(msg.fromUser, botResponse.content);
      }
    } catch (e) {
      print('[BotService] 处理非文本消息失败: $e');
      try {
        await _wechatClient.sendMessage(
          toUser: msg.fromUser,
          content: '抱歉，处理您的消息时出错了',
        );
      } catch (_) {}
    }
  }

  Future<void> _handleImageMessage(WeChatMessage msg) async {
    print('[BotService] ===== 图片识别开始 =====');
    print('[BotService] 消息ID: ${msg.messageId}');
    print('[BotService] 来自用户: ${msg.fromUser}');
    print('[BotService] 图片URL数量: ${msg.imageUrls.length}');

    final imageUrl = msg.imageUrls.first;
    print('[BotService] 下载缩略图: ${imageUrl.substring(0, imageUrl.length > 80 ? 80 : imageUrl.length)}...');

    final imageBase64 = await _wechatClient.downloadImageAsBase64(imageUrl);

    if (imageBase64 == null) {
      print('[BotService] ❌ 图片下载失败，回退到友好提示');
      final fallbackMsg = _generateFallbackReply('image');
      if (fallbackMsg.isNotEmpty) {
        await _wechatClient.sendMessage(
          toUser: msg.fromUser,
          content: fallbackMsg,
        );
      }
      print('[BotService] ===== 图片识别结束(下载失败) =====');
      return;
    }

    print('[BotService] ✅ 图片下载并编码成功 (${(imageBase64.length / 1024).toStringAsFixed(1)}KB)');

    final prompt = msg.content.isNotEmpty && msg.content != '[图片]'
        ? msg.content
        : '请描述这张图片的内容，用简短、口语化的方式回复，像微信聊天一样自然。';

    print('[BotService] 发送图片给 qwen3-vl 模型识别...');
    print('[BotService] Prompt: "$prompt"');

    final startTime = DateTime.now();
    final botResponse = await sendImageMessage(prompt, [imageBase64]);
    final elapsed = DateTime.now().difference(startTime);

    if (botResponse != null && botResponse.type == MessageType.bot) {
      print('[BotService] ✅ AI识别完成 (耗时: ${elapsed.inMilliseconds}ms)');
      print('[BotService] AI回复: ${botResponse.content.substring(0, botResponse.content.length > 100 ? 100 : botResponse.content.length)}...');
      await _sendTextReply(msg.fromUser, botResponse.content);
    } else {
      print('[BotService] ❌ AI识别失败，无有效回复');
    }

    print('[BotService] ===== 图片识别结束 =====');
  }

  String _generateFallbackReply(String messageType) {
    final mode = _config.features.imageHandling.fallbackMode;
    
    if (mode == 'custom' && _config.features.imageHandling.customMsg.isNotEmpty) {
      return _config.features.imageHandling.customMsg;
    }
    
    final replies = {
      'image': '该模型暂时识别不了图片😅',
      'voice': '该模型暂时识别不了语音🎤',
      'video': '该模型暂时识别不了视频🎬',
      'file': '该模型暂时处理不了文件📁',
    };
    
    return replies[messageType] ?? '该模型暂时处理不了此类型消息';
  }

  Future<void> _sendTextReply(String toUser, String replyContent) async {
    var parts = _splitBySpace(replyContent);

    final maxParts = 10;
    final sendParts = parts.length > maxParts ? parts.sublist(0, maxParts) : parts;

    print('[BotService] 发送消息: ${sendParts.length}段 (原${parts.length}段)');
    for (var i = 0; i < sendParts.length; i++) {
      var retryCount = 0;
      const maxRetries = 3;

      while (retryCount < maxRetries) {
        try {
          await _wechatClient.sendMessage(
            toUser: toUser,
            content: sendParts[i],
          );
          print('[BotService] 第${i+1}段发送成功');
          break;
        } catch (e) {
          retryCount++;
          if (retryCount < maxRetries) {
            await Future.delayed(Duration(seconds: retryCount * 2));
          } else {
            print('[BotService] 第${i+1}段发送失败: $e');
          }
        }
      }

      if (i < sendParts.length - 1) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    if (parts.length > maxParts) {
      try {
        await _wechatClient.sendMessage(
          toUser: toUser,
          content: '... (消息过长，已截断显示)',
        );
      } catch (e) {}
    }
  }

  List<String> _splitBySpace(String text) {
    String cleaned = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    cleaned = cleaned.replaceAll(RegExp(r'\n?-{3,}\n?'), '\n');
    cleaned = cleaned.replaceAll(RegExp(r'\[(?:EMOJI|表情).*?\]'), '').trim();

    final lines = cleaned.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final sendText = lines.length <= 1
        ? cleaned
        : lines.map((l) => l.trim()).join(' ');

    final rawParts = sendText
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
      } else if (rawParts[i].length > 1 ||
          rawParts[i].runes.any((r) => r >= 0x4E00 && r <= 0x9FFF)) {
        parts.add(rawParts[i]);
      }
    }

    return parts;
  }

  Future<void> _sendEmojiSticker(String toUser, String keyword) async {
    print('[BotService] ===== 表情包发送开始 =====');
    print('[BotService] 关键词: "$keyword", 目标用户: $toUser');

    try {
      final emojiConfig = _config.features.emojiApi;

      final randomValue = _random.nextDouble();
      final probability = _config.features.emojiProbability;
      print('[BotService] ⑥ 概率掷点: ${randomValue.toStringAsFixed(2)} vs 阈值 ${probability.toStringAsFixed(2)} (需要 ≤)');

      if (randomValue > probability) {
        print('[BotService] → ❌ 概率未通过 (${randomValue.toStringAsFixed(2)} > ${probability.toStringAsFixed(2)})');
        print('[BotService] ===== 表情包发送结束(概率跳过) =====');
        return;
      }

      print('[BotService] → ✅ 概率通过，调用表情API...');
      final imageUrl = await _fetchEmojiUrl(keyword);

      if (imageUrl == null || imageUrl.isEmpty) {
        print('[BotService] → ❌ API未返回有效图片URL');
        print('[BotService] ===== 表情包发送结束(API无结果) =====');
        return;
      }

      print('[BotService] → ✅ 获取到URL: ${imageUrl.length > 60 ? "${imageUrl.substring(0, 60)}..." : imageUrl}');
      print('[BotService] 发送微信图片...');

      final success = await _wechatClient.sendImage(
        toUser: toUser,
        imageUrl: imageUrl,
      );

      if (success) {
        print('[BotService] ✅ 表情包发送成功');
      } else {
        print('[BotService] ❌ 微信图片发送失败');
      }
    } catch (e) {
      print('[BotService] ❌ 表情包发送异常: $e');
    }

    print('[BotService] ===== 表情包发送结束 =====');
  }

  Future<String?> _fetchEmojiUrl(String keyword) async {
    try {
      final emojiConfig = _config.features.emojiApi;

      if (emojiConfig.apiId.isEmpty || emojiConfig.apiUrl.isEmpty) {
        print('[BotService] _fetchEmojiUrl: ❌ apiId或apiUrl为空');
        return null;
      }

      final requestUrl = emojiConfig.apiUrl.contains('?')
          ? emojiConfig.apiUrl.substring(0, emojiConfig.apiUrl.indexOf('?'))
          : emojiConfig.apiUrl;
      print('[BotService] _fetchEmojiUrl: 请求 $requestUrl, keyword="$keyword"');

      final response = await http.get(
        Uri.parse(emojiConfig.apiUrl).replace(queryParameters: {
          'id': emojiConfig.apiId,
          'key': emojiConfig.apiKey,
          'words': keyword,
          'limit': '100',
        }),
      ).timeout(const Duration(seconds: 15));

      print('[BotService] _fetchEmojiUrl: HTTP ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final code = data['code'];
        final hasRes = data['res'] != null;

        print('[BotService] _fetchEmojiUrl: 响应 code=$code, 有res=$hasRes');

        if (code == 200 && hasRes) {
          final urls = List<String>.from(data['res']);
          print('[BotService] _fetchEmojiUrl: 返回 ${urls.length} 张图片');
          if (urls.isNotEmpty) {
            if (urls.length <= 1) return urls.first;
            final unused = urls.where((u) => !_recentEmojiUrls.contains(u)).toList();
            final picked = unused.isNotEmpty
                ? unused[_random.nextInt(unused.length)]
                : urls[_random.nextInt(urls.length)];
            _recentEmojiUrls.add(picked);
            if (_recentEmojiUrls.length > _maxRecentEmojiUrls) {
              _recentEmojiUrls.remove(_recentEmojiUrls.first);
            }
            return picked;
          }
          print('[BotService] _fetchEmojiUrl: 图片列表为空');
        } else {
          print('[BotService] _fetchEmojiUrl: 响应异常 code=$code, body=${response.body.substring(0, response.body.length > 100 ? 100 : response.body.length)}');
        }
      } else {
        print('[BotService] _fetchEmojiUrl: HTTP错误 ${response.statusCode}');
      }

      return null;
    } catch (e) {
      print('[BotService] _fetchEmojiUrl: 异常: $e');
      return null;
    }
  }

  void _startProactiveMessaging() {
    _stopProactiveMessaging();
    
    final intervalMinutes = _config.features.proactiveMessage.intervalMinutes;
    if (intervalMinutes <= 0) return;
    
    _proactiveTimer = Timer.periodic(Duration(minutes: intervalMinutes), (_) async {
      if (!_wechatClient.isConnected) return;
      
      try {
        final now = DateTime.now();
        final maxIdle = Duration(minutes: _config.features.proactiveMessage.maxIdleMinutes);
        final probability = _config.features.proactiveMessage.probability;
        
        for (final entry in List<MapEntry<String, DateTime>>.from(_lastActiveTime.entries)) {
          final userId = entry.key;
          final lastTime = entry.value;
          
          if (now.difference(lastTime) < maxIdle) continue;
          if (_random.nextDouble() > probability) continue;
          
          print('[BotService] 触发主动消息: 用户$userId 空闲${now.difference(lastTime).inMinutes}分钟');
          
          final message = await _generateProactiveMessage(userId);
          
          if (message != null && message.isNotEmpty) {
            await _wechatClient.sendMessage(toUser: userId, content: message);
            _lastActiveTime[userId] = now;
            
            // 记录到历史
            _chatHistory.add(ChatMessage.bot(message));
            print('[BotService] ✅ 主动消息已发送: ${message.substring(0, message.length > 30 ? 30 : message.length)}...');
          }
        }
      } catch (e) {
        print('[BotService] 主动消息异常: $e');
      }
    });
    
    print('[BotService] ✅ 主动消息服务已启动 (间隔: ${intervalMinutes}分钟)');
  }

  Future<String?> _generateProactiveMessage(String userId) async {
    try {
      // 获取最近的聊天记录
      final recentMessages = _chatHistory.where((m) => m.type == MessageType.user || m.type == MessageType.bot).toList();
      final recent = recentMessages.length > 8 ? recentMessages.sublist(recentMessages.length - 8) : recentMessages;
      
      final historyText = recent.map((m) {
        final role = m.type == MessageType.user ? '用户' : '小助手';
        final content = m.content.length > 100 ? '${m.content.substring(0,100)}...' : m.content;
        return '$role: $content';
      }).join('\n');
      
      final botName = _config.skill.enabled && _config.skill.isComplete
          ? _config.skill.configYamlPath.split(Platform.pathSeparator).last
          : '小助手';
      
      final proactivePrompt = '''你正在主动找用户聊天，根据以下最近的聊天记录，自然延续对话：

最近聊天：
${historyText.isEmpty ? '（暂无历史）' : historyText}

请发送一条简短、自然的开场消息（20字以内），用$botName的口吻：
- 延续上次话题或简单问候
- 口语化，带点俏皮
- 不要加 [EMOJI] 标记''';

      final response = await sendUserMessage(proactivePrompt);
      
      if (response != null && response.type == MessageType.bot) {
        // 清理掉刚才添加的历史记录
        if (_chatHistory.length >= 2) {
          _chatHistory.removeLast();
          _chatHistory.removeLast();
        }
        
        return response.content;
      }
      
      return null;
    } catch (e) {
      print('[BotService] 生成主动消息失败: $e');
      return null;
    }
  }

  void _stopProactiveMessaging() {
    _proactiveTimer?.cancel();
    _proactiveTimer = null;
  }

  bool _isDuplicateMessage(String userId, String text) {
    final bytes = utf8.encode(text);
    final hash = md5.convert(bytes).toString().substring(0, 8);
    final msgKey = '$userId:$hash';
    final now = DateTime.now();
    
    if (_processedMessages.containsKey(msgKey)) {
      final lastTime = _processedMessages[msgKey]!;
      if (now.difference(lastTime).inSeconds < _messageDedupeWindow) {
        return true;
      }
    }
    
    _processedMessages[msgKey] = now;
    
    _processedMessages.removeWhere((key, time) => 
      now.difference(time).inSeconds > _messageDedupeWindow * 2
    );
    
    return false;
  }

  void _stopPollingMessages() {
    _pollingActive = false;
    if (_pollWakeUp != null && !_pollWakeUp!.isCompleted) {
      _pollWakeUp!.complete();
    }
    _pollWakeUp = null;
  }

  Future<void> onBackgroundPoll() async {
    if (!_wechatClient.isConnected) return;

    try {
      final messages = await _wechatClient.getUpdates();
      
      for (final msg in messages) {
        if (_isDuplicateMessage(msg.fromUser, msg.content)) {
          continue;
        }

        _lastActiveTime[msg.fromUser] = DateTime.now();

        if (_config.features.typingIndicator) {
          try {
            await _wechatClient.showTyping(msg.fromUser);
          } catch (_) {}
        }

        try {
          if (msg.messageType != 'text') {
            await _handleNonTextMessage(msg);
            return;
          }

          final botResponse = await sendUserMessage(msg.content);

          if (botResponse != null && botResponse.type == MessageType.bot) {
            await _sendTextReply(msg.fromUser, botResponse.content);

            if (botResponse.emojiKeyword?.isNotEmpty == true &&
                _config.features.emoji &&
                _config.features.emojiApi.apiId.isNotEmpty) {
              print('[BotService] [后台] 表情包: 关键词="${botResponse.emojiKeyword}", 概率=${(_config.features.emojiProbability * 100).toInt()}%');
              await _sendEmojiSticker(msg.fromUser, botResponse.emojiKeyword!);
            } else {
              final reasons = <String>[];
              if (botResponse.emojiKeyword?.isNotEmpty != true) reasons.add('关键词为空');
              if (!_config.features.emoji) reasons.add('总开关关闭');
              if (_config.features.emojiApi.apiId.isEmpty) reasons.add('apiId为空');
              print('[BotService] [后台] 表情包跳过: ${reasons.join("、")}');
            }
          }
        } finally {
          if (_config.features.typingIndicator) {
            try {
              await _wechatClient.hideTyping(msg.fromUser);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      print('[BotService] 后台轮询异常: $e');
    }
  }

  Future<void> disconnectWechat() async {
    _stopPollingMessages();
    _stopProactiveMessaging();
    await _wechatClient.disconnect();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('wechat_credentials');
  }

  Future<Map<String, dynamic>> getMemoryStats() async {
    return await _memoryService.getStats();
  }

  Future<List<Map<String, dynamic>>> getRecentMemories({int limit = 20}) async {
    final memories = await _memoryService.getAllMemories(limit: limit);
    return memories.map((m) => {
      'id': m.id,
      'content': m.content,
      'source': m.source,
      'score': m.score,
      'created_at': m.createdAt.toIso8601String(),
    }).toList();
  }

  Future<bool> clearAllMemories() async {
    await _memoryService.clearAllMemories();
    return true;
  }

  Future<bool> clearChatHistory() async {
    _chatHistory.clear();
    return true;
  }

  Future<bool> testLlmConnection() async {
    return await _llmClient.testConnection();
  }

  void dispose() {
    _stopPollingMessages();
    _stopProactiveMessaging();
    _messageStream?.close();
    _messageStream = null;
  }

  Future<void> rebuildSystemPrompt() async {
    await _saveSystemPromptForBackground();
  }
}
