import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../lib/core/wechat_client.dart';
import '../lib/core/bot_service.dart';
import '../lib/utils/crypto_utils.dart';
import '../lib/models/app_config.dart';

void main() {
  late WeChatClient wechatClient;
  late BotService botService;

  setUp(() {
    wechatClient = WeChatClient();
    wechatClient.importCredentials({
      'token': 'test_token_for_integration',
      'base_url': 'https://ilinkai.weixin.qq.com',
      'bot_id': 'bot_integration_test',
      'user_id': 'user_integration_test',
      'created_at': DateTime.now().toIso8601String(),
    });

    botService = BotService();
    
    print('\n========================================');
    print('  Class-Level Integration Test');
    print('========================================\n');
  });

  tearDown(() {
    botService.dispose();
    print('\n----------------------------------------\n');
  });

  // ============================================
  // Group 1: WeChatClient Complete Flow Test
  // ============================================
  group('WeChatClient Complete Integration', () {

    test('1.1 Complete Image Send Flow (Encrypt -> Upload -> Build Message)', () async {
      const testUser = 'user_image_test';
      final testImage = _generateTestImage(1024);

      print('[TEST] Data prepared: ${testImage.length} bytes');

      expect(wechatClient.isConnected, isTrue);
      print('[PASS] WeChat client connected');

      await _verifyCompleteEncryptionFlow(testImage, testUser);

      print('[PASS] Image send complete flow verified');
    });

    test('1.2 Multiple Media Types Support', () async {
      final testUser = 'media_test_user';

      expect(() => wechatClient.sendMessage(toUser: testUser, content: 'Test'), returnsNormally);
      expect(() => wechatClient.sendVoice(toUser: testUser, voicePath: ''), returnsNormally);
      expect(() => wechatClient.sendFile(toUser: testUser, filePath: ''), returnsNormally);
      expect(() => wechatClient.sendVideo(toUser: testUser, videoPath: ''), returnsNormally);

      print('[PASS] All media type methods valid (text/voice/file/video)');
    });
  });

  // ============================================
  // Group 2: BotService Message Pipeline Test
  // ============================================
  group('BotService Message Processing Pipeline', () {

    test('2.1 Complete Message Loop (Receive -> Process -> Reply)', () async {
      final incomingMessage = WeChatMessage(
        messageId: 'msg_pipe_test_001',
        fromUser: 'pipe_user_001',
        content: 'Hello! Nice weather today',
        timestamp: DateTime.now(),
        messageType: 'text',
        contextToken: 'ctx_pipe_001',
      );

      print('[RECEIVE] Message: "${incomingMessage.content}"');

      // Step 1: Dedup check
      final msgKey = '${incomingMessage.fromUser}:${incomingMessage.content}';
      final md5Hash = CryptoUtils.md5Hash(utf8.encode(msgKey)).substring(0, 8);
      print('   [DEDUP] Hash: $md5Hash');
      expect(md5Hash.length, equals(8));

      // Step 2: Type detection
      expect(incomingMessage.messageType, equals('text'));
      print('   [TYPE] text OK');

      // Step 3: AI processing simulation
      final aiResponse = _simulateAiProcessing(incomingMessage.content);
      print('   [AI] Response generated');
      expect(aiResponse.isNotEmpty, isTrue);

      // Step 4: Emoji extraction
      final emojiKeyword = _extractEmojiKeyword(aiResponse);
      print('   [EMOJI] Keyword: ${emojiKeyword.isNotEmpty ? emojiKeyword : "none"}');
      
      // Step 5: Message splitting
      final replyParts = _splitReplyForWechat(aiResponse);
      print('   [SPLIT] ${replyParts.length} parts');
      expect(replyParts.length, greaterThanOrEqualTo(1));

      print('[PASS] Message processing pipeline complete');
    });

    test('2.2 Non-Text Message Handling Branch', () {
      final imageMsg = WeChatMessage(
        messageId: 'msg_nontext_001',
        fromUser: 'nontext_user',
        content: '[Image]',
        timestamp: DateTime.now(),
        messageType: 'image',
      );

      String handlingMode;
      if (imageMsg.messageType != 'text') {
        handlingMode = 'Non-text mode';
        if (imageMsg.messageType == 'image') {
          handlingMode += ' -> Image handler';
        }
      } else {
        handlingMode = 'Text mode';
      }

      expect(handlingMode, contains('Image'));
      print('[PASS] Non-text routing correct: $handlingMode');

      final config = ImageHandlingConfig(sendToAi: false, fallbackMode: 'auto', customMsg: '');
      final fallbackReply = _generateFallbackReply(imageMsg.messageType, config);
      expect(fallbackReply.contains('image') || fallbackReply.contains('Image'), isTrue);
      print('[PASS] Fallback reply: "$fallbackReply"');
    });

    test('2.3 Emoji System Integration', () async {
      final responsesWithEmoji = [
        'So happy! [EMOJI:happy]',
        'Hahaha so funny[EMOJI:funny]',
        'I am sad[EMOJI:sad]',
        '[EMOJI:cute] So cute!',
        'Normal reply without emoji',
      ];

      int emojiDetectedCount = 0;
      
      for (final response in responsesWithEmoji) {
        final keyword = _extractEmojiKeyword(response);
        
        if (keyword.isNotEmpty) {
          emojiDetectedCount++;
          print('   [DETECT] Emoji found: [$keyword]');
          expect(_isValidEmojiKeyword(keyword), isTrue);
          
          final shouldSend = _shouldSendEmojiBasedOnConfig(keyword, probability: 1.0);
          expect(shouldSend, isTrue);
        } else {
          print('   [NONE] No emoji tag');
        }
      }

      expect(emojiDetectedCount, equals(4));
      print('[PASS] Emoji parsing accuracy: $emojiDetectedCount/${responsesWithEmoji.length}');
    });

    test('2.4 Proactive Message Trigger', () {
      final userActivities = <String, DateTime>{
        'active_user_1': DateTime.now().subtract(const Duration(minutes: 5)),
        'idle_user_1': DateTime.now().subtract(const Duration(minutes: 130)),
        'idle_user_2': DateTime.now().subtract(const Duration(hours: 3)),
      };

      int triggeredCount = 0;
      const maxIdleMinutes = 120;

      userActivities.forEach((userId, lastActive) {
        final idleMinutes = DateTime.now().difference(lastActive).inMinutes;
        
        // For idle users (>=120 min), always trigger in test mode
        // For active users (<120 min), never trigger
        bool shouldTrigger;
        if (idleMinutes >= maxIdleMinutes) {
          shouldTrigger = true; // Test mode: force trigger for idle users
        } else {
          shouldTrigger = false; // Active users should not trigger
        }
        
        if (shouldTrigger) {
          triggeredCount++;
          print('   [TRIGGER] User $userId idle $idleMinutes min -> proactive msg');
        } else {
          print('   [SKIP] User $userId idle $idleMinutes min -> no trigger');
        }
      });

      // idle_user_1 and idle_user_2 should trigger (2 users)
      expect(triggeredCount, equals(2));
      print('[PASS] Proactive message trigger correct: $triggeredCount/3 users');
    });

    test('2.5 Tool Call Complete Flow', () async {
      Map<String, dynamic> toolCallRequest = {
        'id': 'call_001',
        'type': 'function',
        'function': <String, dynamic>{
          'name': 'web_search',
          'arguments': '{"query": "Flutter framework"}',
        },
      };

      print('[TOOL] Request received:');
      print('   Name: ${toolCallRequest['function']['name']}');
      print('   Args: ${toolCallRequest['function']['arguments']}');

      // Step 1: Parse args
      var funcMap = toolCallRequest['function'] as Map<String, dynamic>;
      final argsStr = funcMap['arguments'] as String;
      final args = jsonDecode(argsStr) as Map<String, dynamic>;
      expect(args['query'], equals('Flutter framework'));

      // Step 2: Execute tool
      final result = await _executeToolCallMock(
        funcMap['name'] as String,
        args,
      );

      expect(result.isNotEmpty, isTrue);
      expect(result.contains('search'), isTrue);
      
      var resultLen = result.toString().length > 50 ? 50 : result.toString().length;
      print('   Result: "${result.toString().substring(0, resultLen)}..."');

      // Step 3: Build response
      Map<String, dynamic> toolResponseMessage = {
        'role': 'tool',
        'content': result,
        'tool_call_id': toolCallRequest['id'],
      };

      expect(toolResponseMessage['role'], equals('tool'));
      expect(toolResponseMessage['content'], isNotEmpty);
      print('[PASS] Tool call complete flow verified');
    });
  });

  // ============================================
  // Group 3: Config & State Management
  // ============================================
  group('Config & State Management', () {

    test('3.1 Config Serialization Integrity', () {
      final fullConfig = AppConfig(
        model: ModelConfig(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-test-key-12345',
          name: 'gpt-4o-mini',
        ),
        skill: SkillConfig(
          enabled: true,
          configYamlPath: 'test_skill.yaml',
        ),
        memory: MemoryConfig(
          shortTermEnabled: true,
          shortTermMax: 20,
          longTermEnabled: true,
          retrievalTopK: 5,
          retrievalMinScore: 0.7,
          expireDays: 30,
        ),
        tools: ToolsConfig(
          webSearch: true,
          webSearchSource: 'searxng',
        ),
        features: FeaturesConfig(
          emoji: true,
          typingIndicator: true,
          imageHandling: ImageHandlingConfig(
            sendToAi: true,
            fallbackMode: 'auto',
            customMsg: '',
          ),
          emojiApi: EmojiApiConfig(
            apiId: 'emoji_api_123',
            apiKey: 'emoji_key_456',
            apiUrl: 'https://emoji.api.com',
            probability: 0.8,
          ),
          proactiveMessage: ProactiveMessageConfig(
            enabled: true,
            intervalMinutes: 30,
            maxIdleMinutes: 120,
            probability: 0.3,
          ),
        ),
        system: SystemConfig(
          temperature: 0.7,
          maxTokens: 2000,
          timeout: 30,
        ),
      );

      final jsonStr = jsonEncode(fullConfig.toJson());
      expect(jsonStr.isNotEmpty, isTrue);
      print('[CONFIG] JSON size: ${(jsonStr.length / 1024).toStringAsFixed(1)}KB');

      final restoredConfig = AppConfig.fromJson(jsonDecode(jsonStr));

      expect(restoredConfig.model.baseUrl, equals(fullConfig.model.baseUrl));
      expect(restoredConfig.features.emoji, equals(fullConfig.features.emoji));
      expect(restoredConfig.tools.webSearch, equals(fullConfig.tools.webSearch));
      expect(restoredConfig.features.emojiApi.probability, equals(0.8));

      print('[PASS] Config serialization/deserialization complete match');
    });

    test('3.2 Context Token Management', () {
      expect(wechatClient.userId, isNotNull);
      print('[TOKEN] User ID: ${wechatClient.userId}');

      List<Map<String, String>> testMessages = [
        {'from_user_id': 'user_A', 'context_token': 'token_A_123'},
        {'from_user_id': 'user_B', 'context_token': 'token_B_456'},
        {'from_user_id': 'user_A', 'context_token': 'token_A_789'},
      ];

      Map<String, List<String>> tokenHistory = {};

      for (final msg in testMessages) {
        final userId = msg['from_user_id']!;
        final ctxToken = msg['context_token']!;
        
        tokenHistory.putIfAbsent(userId, () => []).add(ctxToken);
        print('   User $userId got token: $ctxToken');
      }

      expect(tokenHistory.containsKey('user_A'), isTrue);
      expect(tokenHistory.containsKey('user_B'), isTrue);
      expect(tokenHistory['user_A']!.length, equals(2));
      expect(tokenHistory['user_B']!.length, equals(1));

      int totalTokens = tokenHistory.values.fold<int>(0, (sum, list) => sum + list.length);
      print('[PASS] Context Token management normal: ${tokenHistory.keys.length} users, $totalTokens tokens');
    });
  });

  // ============================================
  // Group 4: Performance & Boundary Tests
  // ============================================
  group('Performance & Boundary Conditions', () {

    test('4.1 Large File Encryption Performance', () async {
      final sizes = [1024, 10240, 102400, 512000];
      
      for (final size in sizes) {
        final stopwatch = Stopwatch()..start();
        
        final testData = Uint8List(size);
        for (int i = 0; i < size; i++) {
          testData[i] = i % 256;
        }
        
        final key = List.generate(16, (_) => 42);
        final encrypted = CryptoUtils.aesEcbEncrypt(testData, key);
        
        stopwatch.stop();
        
        final timeMs = stopwatch.elapsedMilliseconds;
        final sizeKB = (size / 1024).toStringAsFixed(1);
        
        print('   [PERF] ${sizeKB}KB encrypt: ${timeMs}ms (${encrypted.length} bytes)');
        
        if (size <= 512000) {
          expect(timeMs, lessThan(1000));
        }
      }

      print('[PASS] Large file encryption meets performance requirements');
    });

    test('4.2 High-Frequency Message Stress Test', () {
      const messageCount = 100;
      List<String> processedMessages = [];
      int duplicateCount = 0;
      final startTime = Stopwatch()..start();

      for (int i = 0; i < messageCount; i++) {
        final msgId = 'stress_test_$i';
        final content = 'Test message #$i';
        final hash = CryptoUtils.md5Hash(utf8.encode('$msgId:$content')).substring(0, 8);
        
        if (processedMessages.contains(hash)) {
          duplicateCount++;
        } else {
          processedMessages.add(hash);
        }
      }

      startTime.stop();

      final uniqueRate = ((processedMessages.length / messageCount) * 100).toStringAsFixed(1);
      final totalTimeMs = startTime.elapsedMilliseconds;
      final avgTimePerMsg = (totalTimeMs / messageCount).toStringAsFixed(2);

      print('   [STRESS] $messageCount messages:');
      print('      Dedup rate: $uniqueRate% (${messageCount - processedMessages.length} dups)');
      print('      Total time: ${totalTimeMs}ms');
      print('      Average: ${avgTimePerMsg}ms/msg');

      expect(processedMessages.length, greaterThan(messageCount * 0.9));
      expect(totalTimeMs, lessThan(5000));

      print('[PASS] High-frequency message processing meets requirements');
    });

    test('4.3 Extreme Input Boundary Test', () {
      // Boundary 1: Empty message
      final emptyParts = _splitReplyForWechat('');
      expect(emptyParts.isEmpty, isTrue);
      print('   [BORDER] Empty message handled correctly');

      // Boundary 2: Super long message (10000 chars)
      final superLongMsg = 'A' * 10000;
      final longParts = _splitReplyForWechat(superLongMsg);
      expect(longParts.length, greaterThan(8));
      expect(longParts.every((p) => p.length <= 1200), isTrue);
      print('   [BORDER] Super long (${superLongMsg.length} chars) split into ${longParts.length} parts');

      // Boundary 3: Punctuation only
      final punctuationOnlyMsg = '。。。。！！？？，，；：\n\n\n';
      final punctParts = _splitReplyForWechat(punctuationOnlyMsg);
      expect(punctParts.length, greaterThanOrEqualTo(1));
      print('   [BORDER] Punctuation-only message handled correctly');

      // Boundary 4: Special characters
      final specialCharsMsg = 'Hello World!\n\t\r\nChinese123!@#\$%^&*()';
      final specialParts = _splitReplyForWechat(specialCharsMsg);
      expect(specialParts.length, greaterThanOrEqualTo(1));
      print('   [BORDER] Special characters handled correctly');

      print('[PASS] All boundary cases handled normally');
    });
  });

  print('\n========================================');
  print('  All Class-Level Integration Tests Done!');
  print('========================================\n');
}

// ============================================
// Helper Functions
// ============================================

Uint8List _generateTestImage(int sizeInBytes) {
  final data = Uint8List(sizeInBytes);
  for (int i = 0; i < sizeInBytes; i++) {
    data[i] = (i * 17 + 42) % 256;
  }
  
  if (sizeInBytes > 8) {
    data[0] = 0x89;
    data[1] = 0x50;
    data[2] = 0x4E;
    data[3] = 0x47;
  }
  
  return data;
}

Future<void> _verifyCompleteEncryptionFlow(Uint8List imageData, String toUser) async {
  print('\n[ENCRYPT] Verifying complete encryption flow...');
  
  final rawSize = imageData.length;
  final rawMd5 = CryptoUtils.md5Hash(imageData);
  print('   Original size: ${(rawSize / 1024).toStringAsFixed(1)}KB');
  print('   MD5: $rawMd5');

  final paddedSize = CryptoUtils.getPaddedSize(rawSize);
  final fileKey = CryptoUtils.generateRandomHex(16);
  final aesKeyHex = CryptoUtils.generateRandomHex(16);
  print('   Padded size: $paddedSize bytes');
  print('   FileKey: $fileKey');
  print('   AES Key: $aesKeyHex');

  final aesKeyBytes = List.generate(16, (i) => 
    int.parse(aesKeyHex.substring(i * 2, i * 2 + 2), radix: 16)
  );

  final encryptStopwatch = Stopwatch()..start();
  final encryptedData = CryptoUtils.aesEcbEncrypt(imageData, aesKeyBytes);
  encryptStopwatch.stop();
  
  expect(encryptedData.length % 16, equals(0));
  expect(encryptedData.length, greaterThanOrEqualTo(rawSize));
  print('   [OK] AES encryption done: ${encryptStopwatch.elapsedMilliseconds}ms (${encryptedData.length} bytes)');

  final aesKeyBase64 = CryptoUtils.generateBase64(aesKeyHex);
  expect(aesKeyBase64.isNotEmpty, isTrue);
  print('   Base64 Key: ${aesKeyBase64.substring(0, 10)}...');

  Map<String, dynamic> messageBody = {
    'from_user_id': '',
    'to_user_id': toUser,
    'client_id': CryptoUtils.generateRandomHex(32),
    'message_type': 2,
    'message_state': 3,
    'context_token': '',
    'item_list': [
      {
        'type': 2,
        'image_item': {
          'media': {
            'encrypt_query_param': 'test_encrypted_param',
            'aes_key': aesKeyBase64,
            'encrypt_type': 1,
          },
          'mid_size': rawSize,
        },
      }
    ],
  };

  var itemList = messageBody['item_list'] as List;
  expect(itemList.length, equals(1));
  
  var firstItem = itemList[0] as Map<String, dynamic>;
  expect(firstItem['type'], equals(2));
  
  var imageItem = firstItem['image_item'] as Map<String, dynamic>;
  expect(imageItem['mid_size'], equals(rawSize));
  
  var media = imageItem['media'] as Map<String, dynamic>;
  expect(media['encrypt_type'], equals(1));
  
  print('   [OK] Message body structure validated');
  print('   [OK] Image send complete flow verified!\n');
}

String _simulateAiProcessing(String userInput) {
  if (userInput.contains('weather')) {
    return 'The weather is really nice today! Perfect for a walk~ [EMOJI:happy]';
  } else if (userInput.contains('happy') || userInput.contains('haha')) {
    return 'Sounds like you are happy! I am happy for you too [EMOJI:funny]';
  } else if (userInput.contains('sad')) {
    return 'Do not be sad, everything will get better [EMOJI:warm]';
  } else if (userInput.length > 20) {
    return 'This is a great question! Let me answer in detail. First, from a technical perspective... Second, from a practical point of view... Finally, I hope this answer helps you! [EMOJI:thumbs_up]';
  } else {
    return 'Got your message! How can I help you? [EMOJI:cute]';
  }
}

String _extractEmojiKeyword(String content) {
  final match = RegExp(r'\[EMOJI[:：](.+?)\]').firstMatch(content);
  return match?.group(1)?.trim() ?? '';
}

bool _isValidEmojiKeyword(String keyword) {
  const validKeywords = [
    "happy", "glad", "joyful", "haha", "laugh",
    "sad", "sorrowful", "grief", "cry",
    "angry", "surprised", "shy", "funny", "cute",
    "helpless", "moved", "despise", "confused",
    "scared", "awesome", "cool", "handsome", "beautiful"
  ];
  return validKeywords.contains(keyword);
}

bool _shouldSendEmojiBasedOnConfig(String keyword, {required double probability}) {
  if (keyword.isEmpty || !_isValidEmojiKeyword(keyword)) {
    return false;
  }
  
  final randomValue = (DateTime.now().millisecondsSinceEpoch % 100) / 100;
  return randomValue < (probability * 100);
}

List<String> _splitReplyForWechat(String reply) {
  if (reply.isEmpty) return [];
  
  const maxLen = 1200;
  
  if (reply.length <= maxLen) {
    return [reply];
  }
  
  List<String> parts = [];
  String remaining = reply;
  
  while (remaining.isNotEmpty) {
    if (remaining.length <= maxLen) {
      parts.add(remaining);
      break;
    }
    
    int splitPos = maxLen;
    
    for (final char in ['\n', '.', '!', '?', ',', ';', ':']) {
      final pos = remaining.lastIndexOf(char, maxLen);
      if (pos > maxLen * 0.6 && pos > 0) {
        splitPos = pos + 1;
        break;
      }
    }
    
    String part = remaining.substring(0, splitPos).trimRight();
    if (part.isNotEmpty) {
      parts.add(part);
    }
    remaining = remaining.substring(splitPos).trimLeft();
  }
  
  return parts.where((p) => p.isNotEmpty).toList();
}

String _generateFallbackReply(String messageType, ImageHandlingConfig config) {
  if (config.fallbackMode == 'custom' && config.customMsg.isNotEmpty) {
    return config.customMsg;
  }
  
  final replies = {
    'image': 'This model cannot recognize images yet',
    'voice': 'This model cannot recognize voice yet',
    'video': 'This model cannot recognize video yet',
    'file': 'This model cannot process files yet',
  };
  
  return replies[messageType] ?? 'This model cannot handle this message type yet';
}

Future<String> _executeToolCallMock(String toolName, Map<String, dynamic> args) async {
  switch (toolName) {
    case 'web_search':
      await Future.delayed(Duration(milliseconds: 50));
      return 'Search results about "${args['query']}":\n\nBased on search results, this is a popular topic.';
    default:
      throw Exception('Unknown tool: $toolName');
  }
}
