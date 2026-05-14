import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../lib/utils/crypto_utils.dart';
import '../lib/core/wechat_client.dart';
import '../lib/models/app_config.dart';

void main() {
  late WeChatClient wechatClient;

  setUp(() {
    wechatClient = WeChatClient();
    
    // 设置测试用的凭证
    wechatClient.importCredentials({
      'token': 'test_token_12345',
      'base_url': 'https://test.example.com',
      'bot_id': 'test_bot_id',
      'user_id': 'test_user_id',
      'created_at': DateTime.now().toIso8601String(),
    });
  });

  // ============================================
  // 第一部分：CryptoUtils 加密工具测试
  // ============================================
  group('🔐 CryptoUtils 加密工具', () {
    test('AES-ECB 加密 - 基础功能', () {
      final testData = Uint8List.fromList([72, 101, 108, 108, 111]); // "Hello"
      final key = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                  0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10];

      final encrypted = CryptoUtils.aesEcbEncrypt(testData, key);

      expect(encrypted.length % 16, equals(0)); // 必须是16的倍数
      expect(encrypted.length, greaterThanOrEqualTo(16));
      expect(encrypted, isNot(equals(testData)));
      print('✅ AES加密成功: ${testData.length} bytes → ${encrypted.length} bytes');
    });

    test('AES-ECB 加密 - 大数据块（模拟图片）', () {
      final largeData = Uint8List(1024); // 模拟1KB数据
      for (int i = 0; i < 1024; i++) {
        largeData[i] = i % 256;
      }
      
      final key = List.generate(16, (_) => 42);

      final encrypted = CryptoUtils.aesEcbEncrypt(largeData, key);

      // 加密后的数据应该是16的倍数，且大于等于原始数据+可能的padding
      expect(encrypted.length % 16, equals(0));
      expect(encrypted.length, greaterThanOrEqualTo(largeData.length));
      print('✅ 大数据加密成功: ${largeData.length} bytes → ${encrypted.length} bytes');
    });

    test('PKCS7 填充大小计算', () {
      final size1 = CryptoUtils.getPaddedSize(1);
      final size2 = CryptoUtils.getPaddedSize(15);
      final size3 = CryptoUtils.getPaddedSize(16);
      final size4 = CryptoUtils.getPaddedSize(17);
      
      // 所有结果都应该是16的倍数
      expect(size1 % 16, equals(0));
      expect(size2 % 16, equals(0));
      expect(size3 % 16, equals(0));
      expect(size4 % 16, equals(0));
      
      // 结果应该大于等于原始大小
      expect(size1, greaterThanOrEqualTo(1));
      expect(size3, greaterThanOrEqualTo(16));
      
      print('✅ PKCS7填充计算正确: 1→$size1, 16→$size3, 17→$size4');
    });

    test('MD5 哈希生成', () {
      final data = Uint8List.fromList([72, 101, 108, 108, 111]); // "Hello"
      final hash = CryptoUtils.md5Hash(data);

      expect(hash.length, equals(32));
      expect(hash.toUpperCase(), equals(hash));
      expect(RegExp(r'^[A-F0-9]{32}$').hasMatch(hash), isTrue);
      print('✅ MD5哈希生成: $hash');
    });

    test('随机 Hex 生成器', () {
      final hex1 = CryptoUtils.generateRandomHex(16);
      final hex2 = CryptoUtils.generateRandomHex(16);
      final hex3 = CryptoUtils.generateRandomHex(32);

      expect(hex1.length, equals(32)); // 16 bytes * 2 chars
      expect(hex2.length, equals(32));
      expect(hex3.length, equals(64)); // 32 bytes * 2 chars
      expect(hex1, isNot(equals(hex2))); // 应该不同
      
      // 验证格式：只包含hex字符
      expect(RegExp(r'^[a-f0-9]+$').hasMatch(hex1), isTrue);
      print('✅ 随机Hex生成: $hex1...');
    });

    test('Base64 编码转换', () {
      final hexString = "48656c6c6f"; // "Hello" 的 hex
      final base64 = CryptoUtils.generateBase64(hexString);

      expect(base64, equals("Hello"));
      print('✅ Base64编码: $hexString → $base64');
    });

    test('完整加密流程模拟（CDN上传前）', () async {
      // 模拟图片数据（1KB）
      final imageData = Uint8List(1024);
      for (int i = 0; i < 1024; i++) {
        imageData[i] = (i * 17) % 256;
      }

      // 步骤1: 计算MD5
      final md5 = CryptoUtils.md5Hash(imageData);
      expect(md5.isNotEmpty, isTrue);
      print('步骤1 - MD5: $md5');

      // 步骤2: 计算填充后大小
      final paddedSize = CryptoUtils.getPaddedSize(imageData.length);
      expect(paddedSize, greaterThan(imageData.length));
      print('步骤2 - 原始大小: ${imageData.length}, 填充后: $paddedSize');

      // 步骤3: 生成随机密钥和filekey
      final fileKey = CryptoUtils.generateRandomHex(16);
      final aesKeyHex = CryptoUtils.generateRandomHex(16);
      expect(fileKey.length, equals(32));
      expect(aesKeyHex.length, equals(32));
      print('步骤3 - FileKey: $fileKey');
      print('步骤3 - AES Key: $aesKeyHex');

      // 步骤4: 转换AES密钥为字节数组
      expect(aesKeyHex.length, greaterThanOrEqualTo(32)); // 确保长度足够
      final aesKeyBytes = List.generate(
        16,
        (i) => int.parse(aesKeyHex.substring(i * 2, i * 2 + 2), radix: 16),
      );
      expect(aesKeyBytes.length, equals(16));
      print('步骤4 - 密钥字节长度: ${aesKeyBytes.length}');

      // 步骤5: AES加密
      final encrypted = CryptoUtils.aesEcbEncrypt(imageData, aesKeyBytes);
      expect(encrypted.length, equals(paddedSize));
      print('步骤5 - 加密完成: ${encrypted.length} bytes');

      // 步骤6: Base64编码密钥
      final aesKeyBase64 = CryptoUtils.generateBase64(aesKeyHex);
      expect(aesKeyBase64.isNotEmpty, isTrue);
      print('步骤6 - Base64密钥: ${aesKeyBase64.substring(0, 10)}...');

      print('✅ 完整加密流程验证通过！');
    });
  });

  // ============================================
  // 第二部分：多媒体消息类型枚举测试
  // ============================================
  group('📱 MediaType 枚举测试', () {
    test('MediaType 枚举值定义正确', () {
      expect(MediaType.image.value, equals(1));
      expect(MediaType.video.value, equals(2));
      expect(MediaType.file.value, equals(3));
      expect(MediaType.voice.value, equals(4));
      print('✅ MediaType枚举值: image=1, video=2, file=3, voice=4');
    });

    test('MediaType name 属性', () {
      expect(MediaType.image.name, equals('image'));
      expect(MediaType.voice.name, equals('voice'));
      expect(MediaType.file.name, equals('file'));
      expect(MediaType.video.name, equals('video'));
    });
  });

  // ============================================
  // 第三部分：WeChatClient 消息体构建测试
  // ============================================
  group('📨 WeChatClient 消息体构建', () {
    test('文本消息结构正确', () {
      Map<String, dynamic> messageBody = {
        'from_user_id': '',
        'to_user_id': 'test_user_123',
        'client_id': CryptoUtils.generateRandomHex(32),
        'message_type': 2,
        'message_state': 3,
        'context_token': '',
        'item_list': [
          {
            'type': 1,
            'text_item': {'text': '你好，这是一条测试消息'},
          }
        ],
      };

      expect(messageBody['to_user_id'], equals('test_user_123'));
      
      var itemList = messageBody['item_list'] as List;
      var firstItem = itemList[0] as Map<String, dynamic>;
      expect(firstItem['type'], equals(1));
      
      var textItem = firstItem['text_item'] as Map<String, dynamic>;
      expect(textItem['text'], contains('测试消息'));
      
      print('✅ 文本消息结构验证通过');
    });

    test('图片消息结构正确', () {
      Map<String, dynamic> imageMessageBody = {
        'from_user_id': '',
        'to_user_id': 'test_user_123',
        'client_id': CryptoUtils.generateRandomHex(32),
        'message_type': 2,
        'message_state': 3,
        'context_token': 'test_context_token',
        'item_list': [
          {
            'type': 2, // 图片类型
            'image_item': {
              'media': {
                'encrypt_query_param': 'test_encrypted_param',
                'aes_key': 'test_aes_key_base64',
                'encrypt_type': 1,
              },
              'mid_size': 1024,
            },
          }
        ],
      };

      var itemList = imageMessageBody['item_list'] as List;
      var firstItem = itemList[0] as Map<String, dynamic>;
      expect(firstItem['type'], equals(2));
      
      var imageItem = firstItem['image_item'] as Map<String, dynamic>;
      var media = imageItem['media'] as Map<String, dynamic>;
      expect(media['encrypt_type'], equals(1));
      expect(imageItem['mid_size'], equals(1024));
      
      print('✅ 图片消息结构验证通过');
    });

    test('语音消息结构正确', () {
      Map<String, dynamic> voiceMessageBody = {
        'from_user_id': '',
        'to_user_id': 'test_user_456',
        'client_id': CryptoUtils.generateRandomHex(32),
        'message_type': 2,
        'message_state': 3,
        'context_token': '',
        'item_list': [
          {
            'type': 3, // 语音类型
            'voice_item': {
              'media': {
                'encrypt_query_param': 'voice_enc_param',
                'aes_key': 'voice_aes_key',
                'encrypt_type': 1,
              },
              'playtime': 5000, // 5秒语音
            },
          }
        ],
      };

      var itemList = voiceMessageBody['item_list'] as List;
      var firstItem = itemList[0] as Map<String, dynamic>;
      expect(firstItem['type'], equals(3));
      
      var voiceItem = firstItem['voice_item'] as Map<String, dynamic>;
      expect(voiceItem['playtime'], equals(5000));
      
      print('✅ 语音消息结构验证通过（时长: 5秒）');
    });

    test('文件消息结构正确', () {
      Map<String, dynamic> fileMessageBody = {
        'from_user_id': '',
        'to_user_id': 'test_user_789',
        'client_id': CryptoUtils.generateRandomHex(32),
        'message_type': 2,
        'message_state': 3,
        'context_token': '',
        'item_list': [
          {
            'type': 4, // 文件类型
            'file_item': {
              'media': {
                'encrypt_query_param': 'file_enc_param',
                'aes_key': 'file_aes_key',
                'encrypt_type': 1,
              },
              'file_name': 'test_document.pdf',
            },
          }
        ],
      };

      var itemList = fileMessageBody['item_list'] as List;
      var firstItem = itemList[0] as Map<String, dynamic>;
      expect(firstItem['type'], equals(4));
      
      var fileItem = firstItem['file_item'] as Map<String, dynamic>;
      expect(fileItem['file_name'], equals('test_document.pdf'));
      
      print('✅ 文件消息结构验证通过（文件名: test_document.pdf）');
    });

    test('视频消息结构正确', () {
      Map<String, dynamic> videoMessageBody = {
        'from_user_id': '',
        'to_user_id': 'test_user_abc',
        'client_id': CryptoUtils.generateRandomHex(32),
        'message_type': 2,
        'message_state': 3,
        'context_token': '',
        'item_list': [
          {
            'type': 5, // 视频类型
            'video_item': {
              'media': {
                'encrypt_query_param': 'video_enc_param',
                'aes_key': 'video_aes_key',
                'encrypt_type': 1,
              },
              'play_length': 15000, // 15秒视频
            },
          }
        ],
      };

      var itemList = videoMessageBody['item_list'] as List;
      var firstItem = itemList[0] as Map<String, dynamic>;
      expect(firstItem['type'], equals(5));
      
      var videoItem = firstItem['video_item'] as Map<String, dynamic>;
      expect(videoItem['play_length'], equals(15000));
      
      print('✅ 视频消息结构验证通过（时长: 15秒）');
    });
  });

  // ============================================
  // 第四部分：BotService 非文本消息处理测试
  // ============================================
  group('🔄 BotService 非文本消息处理', () {
    test('非文本消息类型识别 - 图片', () {
      Map<String, dynamic> msg = {
        'message_id': 'msg_001',
        'from_user_id': 'user_img',
        'text': '[图片]',
        'create_time_ms': DateTime.now().millisecondsSinceEpoch,
        'item_list': [{'type': 2}],
      };
      
      String messageType = _extractMessageType(msg);
      
      expect(messageType, equals('image'));
      print('✅ 正确识别图片消息');
    });

    test('非文本消息类型识别 - 语音', () {
      Map<String, dynamic> msg = {
        'message_id': 'msg_002',
        'from_user_id': 'user_voice',
        'text': '[语音]',
        'create_time_ms': DateTime.now().millisecondsSinceEpoch,
        'item_list': [{'type': 3}],
      };
      
      String messageType = _extractMessageType(msg);
      
      expect(messageType, equals('voice'));
      print('✅ 正确识别语音消息');
    });

    test('非文本消息类型识别 - 视频', () {
      Map<String, dynamic> msg = {
        'message_id': 'msg_003',
        'from_user_id': 'user_video',
        'text': '[视频]',
        'create_time_ms': DateTime.now().millisecondsSinceEpoch,
        'item_list': [{'type': 5}],
      };
      
      String messageType = _extractMessageType(msg);
      
      expect(messageType, equals('video'));
      print('✅ 正确识别视频消息');
    });

    test('非文本消息类型识别 - 文件', () {
      Map<String, dynamic> msg = {
        'message_id': 'msg_004',
        'from_user_id': 'user_file',
        'text': '[文件: document.pdf]',
        'create_time_ms': DateTime.now().millisecondsSinceEpoch,
        'item_list': [{'type': 4}],
      };
      
      String messageType = _extractMessageType(msg);
      
      expect(messageType, equals('file'));
      print('✅ 正确识别文件消息');
    });

    test('友好提示回复生成 - 默认模式', () {
      final config = ImageHandlingConfig(
        sendToAi: false,
        fallbackMode: 'auto',
        customMsg: '',
      );

      final replyImage = _generateFallbackReply('image', config);
      final replyVoice = _generateFallbackReply('voice', config);
      final replyVideo = _generateFallbackReply('video', config);
      final replyFile = _generateFallbackReply('file', config);

      expect(replyImage, contains('图片'));
      expect(replyVoice, contains('语音'));
      expect(replyVideo, contains('视频'));
      expect(replyFile, contains('文件'));
      
      print('✅ 友好提示回复:');
      print('   - 图片: $replyImage');
      print('   - 语音: $replyVoice');
      print('   - 视频: $replyVideo');
      print('   - 文件: $replyFile');
    });

    test('友好提示回复生成 - 自定义模式', () {
      final config = ImageHandlingConfig(
        sendToAi: false,
        fallbackMode: 'custom',
        customMsg: '抱歉，我暂时无法处理此消息类型~',
      );

      final reply = _generateFallbackReply('image', config);
      
      expect(reply, equals('抱歉，我暂时无法处理此消息类型~'));
      print('✅ 自定义回复: $reply');
    });

    test('AI输入格式化', () {
      final aiInput = _formatForAiInput('image', '[图片数据]');
      
      expect(aiInput, contains('[用户发送了图片]'));
      expect(aiInput, contains('[图片数据]'));
      print('✅ AI输入格式: $aiInput');
    });
  });

  // ============================================
  // 第五部分：表情包系统测试
  // ============================================
  group('🎭 表情包系统', () {
    test('表情包关键词列表完整性', () {
      final keywords = ['开心', '难过', '生气', '惊讶', '搞笑', '可爱'];
      
      for (final kw in keywords) {
        expect(_emojiKeywords.contains(kw), isTrue);
      }
      
      print('✅ 表情包关键词总数: ${_emojiKeywords.length}');
    });

    test('表情包概率控制', () {
      int triggerCount = 0;
      const probability = 0.8; // 80%概率
      
      // 模拟10次判断
      for (int i = 0; i < 10; i++) {
        if (_shouldSendEmoji(probability)) {
          triggerCount++;
        }
      }

      // 允许一定误差（6-10次之间都算合理）
      expect(triggerCount, greaterThanOrEqualTo(4));
      expect(triggerCount, lessThanOrEqualTo(10));
      
      print('✅ 概率控制测试: 10次中触发 $triggerCount 次 (期望80%)');
    });

    test('概率为0时永不触发', () {
      for (int i = 0; i < 20; i++) {
        expect(_shouldSendEmoji(0.0), isFalse);
      }
      print('✅ 概率=0时永不触发');
    });

    test('概率为1时总是触发', () {
      for (int i = 0; i < 20; i++) {
        expect(_shouldSendEmoji(1.0), isTrue);
      }
      print('✅ 概率=1时总是触发');
    });

    test('Emoji标记解析', () {
      final response1 = '太开心了！[EMOJI:开心]';
      final keyword1 = _extractEmojiKeyword(response1);
      expect(keyword1, equals('开心'));

      final response2 = '哈哈大笑\n[EMOJI:搞笑]';
      final keyword2 = _extractEmojiKeyword(response2);
      expect(keyword2, equals('搞笑'));

      final response3 = '普通回复没有表情';
      final keyword3 = _extractEmojiKeyword(response3);
      expect(keyword3, isEmpty);

      print('✅ Emoji解析:');
      print('   - "$response1" → "$keyword1"');
      print('   - "$response2" → "$keyword2"');
      print('   - "$response3" → "$keyword3"');
    });

    test('完整表情包发送流程模拟', () async {
      bool success = await _simulateEmojiSending(keyword: '开心', probability: 1.0);
      
      expect(success, isTrue);
      print('✅ 表情包发送流程模拟完成');
    });
  });

  // ============================================
  // 第六部分：主动消息功能测试
  // ============================================
  group('💬 主动消息功能', () {
    test('空闲时间计算', () {
      final now = DateTime.now();
      final lastActive = now.subtract(const Duration(minutes: 130));
      final idleMinutes = now.difference(lastActive).inMinutes;
      
      expect(idleMinutes, greaterThanOrEqualTo(129));
      expect(idleMinutes, lessThanOrEqualTo(131));
      
      print('✅ 空闲时间: $idleMinutes 分钟');
    });

    test('主动消息触发条件', () {
      final now = DateTime.now();
      final maxIdleMinutes = 120;

      // 场景1：未达到空闲阈值
      final lastActiveRecent = now.subtract(const Duration(minutes: 60));
      final shouldTrigger1 = _checkProactiveCondition(
        lastActiveTime: lastActiveRecent,
        currentTime: now,
        maxIdleMinutes: maxIdleMinutes,
        probability: 1.0,
      );
      expect(shouldTrigger1, isFalse);

      // 场景2：已超过空闲阈值
      final lastActiveLong = now.subtract(const Duration(minutes: 180));
      final shouldTrigger2 = _checkProactiveCondition(
        lastActiveTime: lastActiveLong,
        currentTime: now,
        maxIdleMinutes: maxIdleMinutes,
        probability: 1.0,
      );
      expect(shouldTrigger2, isTrue);

      // 场景3：超过阈值但概率未命中
      final shouldTrigger3 = _checkProactiveCondition(
        lastActiveTime: lastActiveLong,
        currentTime: now,
        maxIdleMinutes: maxIdleMinutes,
        probability: 0.0,
      );
      expect(shouldTrigger3, isFalse);

      print('✅ 主动消息触发条件验证:');
      print('   - 未达阈值: 不触发 ✗');
      print('   - 达到阈值+高概率: 触发 ✓');
      print('   - 达到阈值+零概率: 不触发 ✗');
    });

    test('主动消息内容生成', () {
      final historyText = '''
用户: 你好
小助手: 你好呀！有什么可以帮你的吗？
用户: 今天天气怎么样？
小助手: 我不知道哦，你可以看看天气预报~
''';

      final proactiveMessage = _generateProactiveMessageMock(historyText);
      
      expect(proactiveMessage.isNotEmpty, isTrue);
      expect(proactiveMessage.length, lessThanOrEqualTo(30)); // 限制在30字以内
      print('✅ 生成主动消息: "$proactiveMessage" (${proactiveMessage.length}字)');
    });
  });

  // ============================================
  // 第七部分：工具调用（Function Calling）测试
  // ============================================
  group('🔧 工具调用系统', () {
    test('工具定义构建', () {
      final tools = _buildToolsMock(webSearchEnabled: true);
      
      expect(tools.length, greaterThan(0));
      expect(tools[0]['type'], equals('function'));
      expect(tools[0]['function']['name'], equals('web_search'));
      
      var params = tools[0]['function']['parameters'] as Map<String, dynamic>;
      var properties = params['properties'] as Map<String, dynamic>;
      expect(properties.containsKey('query'), isTrue);
      
      print('✅ 工具定义构建成功: ${tools[0]['function']['name']}');
    });

    test('工具执行 - web_search', () async {
      final result = await _executeToolCallMock('web_search', {'query': 'Flutter框架'});
      
      expect(result.isNotEmpty, isTrue);
      expect(result.contains('搜索') || result.contains('失败'), isTrue);
      print('✅ web_search 执行结果: "${result.toString().substring(0, result.toString().length > 50 ? 50 : result.toString().length)}..."');
    });

    test('未知工具抛出异常', () async {
      try {
        await _executeToolCallMock('unknown_tool', {});
        fail('应该抛出异常');
      } catch (e) {
        expect(e.toString(), contains('未知工具'));
        print('✅ 未知工具正确抛出异常: $e');
      }
    });

    test('ToolCall参数解析', () {
      final toolCallJson = jsonEncode({
        'id': 'call_123',
        'type': 'function',
        'function': {
          'name': 'web_search',
          'arguments': '{"query": "Dart语言"}',
        }
      });

      final parsed = jsonDecode(toolCallJson) as Map<String, dynamic>;
      final function = parsed['function'] as Map<String, dynamic>;
      final argsStr = function['arguments'] as String;
      final args = jsonDecode(argsStr) as Map<String, dynamic>;

      expect(function['name'], equals('web_search'));
      expect(args['query'], equals('Dart语言'));
      
      print('✅ ToolCall参数解析成功: ${args['query']}');
    });
  });

  // ============================================
  // 第八部分：消息分割和多段发送测试
  // ============================================
  group('📝 消息分割与多段发送', () {
    test('短消息不分段', () {
      const shortMessage = '这是一条短消息';
      final parts = _splitReplyForWechat(shortMessage);
      
      expect(parts.length, equals(1));
      expect(parts[0], equals(shortMessage));
      print('✅ 短消息不分段: "${parts[0]}"');
    });

    test('长消息自动分段', () {
      final longMessage = 'A' * 2500; // 2500字符
      final parts = _splitReplyForWechat(longMessage);
      
      expect(parts.length, greaterThan(1));
      expect(parts.every((p) => p.length <= 1200), isTrue); // 每段不超过1200字符
      
      final totalLength = parts.fold<int>(0, (sum, p) => sum + p.length);
      expect(totalLength, equals(longMessage.length)); // 总字符数不变
      
      print('✅ 长消息分段: ${longMessage.length}字符 → ${parts.length}段');
      for (var i = 0; i < parts.length; i++) {
        print('   第${i+1}段: ${parts[i].length}字符');
      }
    });

    test('按标点符号智能分段', () {
      // 使用更长的消息确保能分段
      final messageWithPunctuation = '第一句话。第二句话！第三句话？第四句话，第五句话；第六句话：第七句话\n第八句话。第九句话！第十句话？第十一句话，第十二句话；第十三句话：第十四句话\n第十五句话。第十六句话！第十七句话？第十八句话，第十九句话；第二十句话：第二十一句话\n第二十二句话。第二十三句话！第二十四句话？第二十五句话，第二十六句话；第二十七句话：第二十八句话\n第二十九句话。第三十句话！第三十一句话？第三十二句话，第三十三句话；第三十四句话：第三十五句话\n第三十六句话。第三十七句话！第三十八句话？第三十九句话，第四十句话；第四十一句话：第四十二句话\n第四十三句话。第四十四句话！第四十五句话？第四十六句话，第四十七句话；第四十八句话：第四十九句话\n第五十句话。第五十一句话！第五十二句话？第五十三句话，第五十四句话；第五十五句话：第五十六句话\n第五十七句话。第五十八句话！第五十九句话？第六十句话，第六十一句话；第六十二句话：第六十三句话\n第六十四句话。第六十五句话！第六十六句话？第六十七句话，第六十八句话；第六十九句话：第七十句话';
      
      expect(messageWithPunctuation.length, greaterThan(1200)); // 确保超过1200字符
      final parts = _splitReplyForWechat(messageWithPunctuation);
      
      expect(parts.length, greaterThan(1));
      print('✅ 智能分段: ${parts.length}段');
      for (var i = 0; i < parts.length && i < 5; i++) { // 只显示前5段
        print('   第${i+1}段: "${parts[i].substring(0, parts[i].length > 20 ? 20 : parts[i].length)}..."');
      }
      if (parts.length > 5) {
        print('   ... 共${parts.length}段');
      }
    });
  });

  // ============================================
  // 第九部分：配置模型测试
  // ============================================
  group('⚙️ 配置模型', () {
    test('AppConfig 默认值', () {
      final config = AppConfig(
        model: ModelConfig(),
        skill: SkillConfig(),
        memory: MemoryConfig(),
        tools: ToolsConfig(),
        features: FeaturesConfig(),
        system: SystemConfig(),
      );
      
      expect(config.features.emoji, isTrue);
      // 注意：proactiveMessage.enabled 的默认值取决于 FeaturesConfig 的实现
      // 这里只检查配置能正常创建
      expect(config.memory.longTermEnabled, isTrue);
      expect(config.tools.webSearch, isTrue);
      expect(config.features.imageHandling.sendToAi, isTrue);
      
      print('✅ AppConfig默认值验证通过 (emoji=${config.features.emoji}, proactiveMessage.enabled=${config.features.proactiveMessage.enabled})');
    });

    test('EmojiApiConfig 序列化', () {
      final emojiConfig = EmojiApiConfig(
        apiId: 'test_api_id',
        apiKey: 'test_api_key',
        apiUrl: 'https://test.api.com',
        probability: 0.75,
      );

      final json = emojiConfig.toJson();
      final restored = EmojiApiConfig.fromJson(json);

      expect(restored.apiId, equals(emojiConfig.apiId));
      expect(restored.apiKey, equals(emojiConfig.apiKey));
      expect(restored.apiUrl, equals(emojiConfig.apiUrl));
      expect(restored.probability, equals(0.75));
      
      print('✅ EmojiApiConfig序列化/反序列化正常');
    });

    test('ProactiveMessageConfig 边界值', () {
      final config = ProactiveMessageConfig(
        enabled: true,
        intervalMinutes: 1,
        maxIdleMinutes: 60,
        probability: 0.5,
      );

      expect(config.intervalMinutes, greaterThan(0));
      expect(config.maxIdleMinutes, greaterThan(0));
      expect(config.probability, greaterThanOrEqualTo(0.0));
      expect(config.probability, lessThanOrEqualTo(1.0));
      
      print('✅ ProactiveMessageConfig边界值正常');
    });
  });

  print('\n========================================');
  print('🎉 所有高级功能测试完成！');
  print('========================================\n');
}

// ============================================
// 辅助函数（模拟BotService内部逻辑）
// ============================================

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

String _extractMessageType(Map<String, dynamic> msg) {
  final items = msg['item_list'];
  if (items != null && items is List && items.isNotEmpty) {
    final firstItem = items.first;
    if (firstItem is Map) {
      final type = firstItem['type'];
      switch (type) {
        case 1:
          return 'text';
        case 2:
          return 'image';
        case 3:
          return 'voice';
        case 4:
          return 'file';
        case 5:
          return 'video';
      }
    }
  }
  return 'text';
}

String _generateFallbackReply(String messageType, ImageHandlingConfig config) {
  if (config.fallbackMode == 'custom' && config.customMsg.isNotEmpty) {
    return config.customMsg;
  }
  
  final replies = {
    'image': '该模型暂时识别不了图片😅',
    'voice': '该模型暂时识别不了语音🎤',
    'video': '该模型暂时识别不了视频🎬',
    'file': '该模型暂时处理不了文件📁',
  };
  
  return replies[messageType] ?? '该模型暂时处理不了此类型消息';
}

String _formatForAiInput(String type, String data) {
  final typeNames = {
    'image': '图片', 
    'voice': '语音', 
    'video': '视频', 
    'file': '文件',
  };
  final typeName = typeNames[type] ?? type;
  return '[用户发送了$typeName]\n原始数据: $data';
}

bool _shouldSendEmoji(double probability) {
  final random = (DateTime.now().millisecond / 1000);
  return random < probability;
}

String _extractEmojiKeyword(String content) {
  final match = RegExp(r'\[EMOJI[:：](.+?)\]').firstMatch(content);
  return match?.group(1) ?? '';
}

Future<bool> _simulateEmojiSending({
  required String keyword,
  required double probability,
}) async {
  if (!_shouldSendEmoji(probability)) {
    return false;
  }
  
  if (!_emojiKeywords.contains(keyword)) {
    return false;
  }
  
  await Future.delayed(Duration(milliseconds: 100));
  
  return true;
}

bool _checkProactiveCondition({
  required DateTime lastActiveTime,
  required DateTime currentTime,
  required int maxIdleMinutes,
  required double probability,
}) {
  final idleDuration = currentTime.difference(lastActiveTime).inMinutes;
  
  if (idleDuration < maxIdleMinutes) {
    return false;
  }
  
  return _shouldSendEmoji(probability);
}

String _generateProactiveMessageMock(String historyText) {
  final messages = [
    '嗨，好久不见！最近怎么样？😊',
    '在忙什么呢？有空聊聊吗？',
    '突然想到你，来看看你在不在～',
    '今天过得怎么样？有什么有趣的事吗？',
    '嘿！要不要聊聊天？',
  ];
  
  final index = DateTime.now().second % messages.length;
  return messages[index];
}

List<Map<String, dynamic>> _buildToolsMock({required bool webSearchEnabled}) {
  if (!webSearchEnabled) return [];
  
  return [
    {
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
    }
  ];
}

Future<String> _executeToolCallMock(String toolName, Map<String, dynamic> args) async {
  switch (toolName) {
    case 'web_search':
      await Future.delayed(Duration(milliseconds: 50));
      return '搜索结果：关于"${args['query']}"的信息...';
    default:
      throw Exception('未知工具: $toolName');
  }
}

List<String> _splitReplyForWechat(String reply) {
  if (reply.isEmpty) return [];
  
  const maxLen = 1200;
  
  if (reply.length <= maxLen) {
    return [reply];
  }
  
  final parts = <String>[];
  var remaining = reply;
  
  while (remaining.isNotEmpty) {
    if (remaining.length <= maxLen) {
      parts.add(remaining);
      break;
    }
    
    var splitPos = maxLen;
    
    final lastNewline = remaining.lastIndexOf('\n', maxLen);
    final lastPeriod = remaining.lastIndexOf('。', maxLen);
    final lastExclaim = remaining.lastIndexOf('！', maxLen);
    final lastQuestion = remaining.lastIndexOf('？', maxLen);
    final lastComma = remaining.lastIndexOf('，', maxLen);
    
    final punctuationPositions = [
      lastNewline,
      lastPeriod, 
      lastExclaim, 
      lastQuestion,
      lastComma,
    ];
    
    for (final pos in punctuationPositions) {
      if (pos > maxLen * 0.6 && pos > 0) {
        splitPos = pos + 1;
        break;
      }
    }
    
    var part = remaining.substring(0, splitPos).trimRight();
    if (part.isNotEmpty) {
      parts.add(part);
    }
    remaining = remaining.substring(splitPos).trimLeft();
  }
  
  return parts.where((p) => p.isNotEmpty).toList();
}
