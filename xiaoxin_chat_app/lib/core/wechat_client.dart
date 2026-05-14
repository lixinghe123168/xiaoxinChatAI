import 'dart:convert';
import 'dart:io' show Platform, File;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path_lib;
import '../utils/crypto_utils.dart';

enum MediaType {
  image(1),
  video(2),
  file(3),
  voice(4);

  final int value;
  const MediaType(this.value);
}

class WeChatCredentials {
  final String token;
  final String baseUrl;
  final String botId;
  final String userId;
  final DateTime createdAt;

  const WeChatCredentials({
    required this.token,
    required this.baseUrl,
    required this.botId,
    required this.userId,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'token': token,
        'base_url': baseUrl,
        'bot_id': botId,
        'user_id': userId,
        'created_at': createdAt.toIso8601String(),
      };

  factory WeChatCredentials.fromJson(Map<String, dynamic> json) {
    return WeChatCredentials(
      token: json['token'] ?? '',
      baseUrl: json['base_url'] ?? '',
      botId: json['bot_id'] ?? '',
      userId: json['user_id'] ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : DateTime.now(),
    );
  }

  bool get isValid =>
      token.isNotEmpty && botId.isNotEmpty && userId.isNotEmpty;
}

class QrCodeResult {
  final String qrcodeKey;
  final String qrcodeImageUrl;

  const QrCodeResult({
    required this.qrcodeKey,
    required this.qrcodeImageUrl,
  });
}

class QrCodeStatus {
  static const waiting = 'waiting';
  static const scanned = 'scanned';
  static const confirmed = 'confirmed';
  static const expired = 'expired';
  static const error = 'error';

  final String status;
  final String? message;
  final String? botId;
  final String? userId;
  final String? token; // 新增：直接从状态响应获取token

  const QrCodeStatus({
    required this.status,
    this.message,
    this.botId,
    this.userId,
    this.token,
  });

  bool get isConfirmed => status == confirmed;
  bool get isScanned => status == scanned;
  bool get isWaiting => status == waiting || status == scanned;
  bool get isExpired => status == expired;
}

class WeChatMessage {
  final String messageId;
  final String fromUser;
  final String content;
  final DateTime timestamp;
  final String messageType;
  final String? contextToken;
  final List<String> imageUrls;
  final String? rawImageData;

  const WeChatMessage({
    required this.messageId,
    required this.fromUser,
    required this.content,
    required this.timestamp,
    this.messageType = 'text',
    this.contextToken,
    this.imageUrls = const [],
    this.rawImageData,
  });
}

class WeChatClient {
  static const String defaultBaseUrl = 'https://ilinkai.weixin.qq.com';
  static const String corsProxyUrl = 'https://cors-anywhere.herokuapp.com/';
  static const String channelVersion = '1.0.3';

  String _baseUrl = defaultBaseUrl;
  WeChatCredentials? _credentials;
  bool _useCorsProxy = false;

  final Map<String, String> _contextTokens = {};

  String get baseUrl => _baseUrl;
  bool get isConnected => _credentials?.isValid ?? false;
  String? get userId => _credentials?.userId;

  void setBaseUrl(String url) {
    _baseUrl = url.isEmpty ? defaultBaseUrl : url.replaceAll(RegExp(r'/$'), '');
  }

  void enableCorsProxy(bool enable) {
    _useCorsProxy = enable;
  }

  String _getProxiedUrl(String url) {
    if (_useCorsProxy && !_isRunningOnNativePlatform()) {
      return '$corsProxyUrl$url';
    }
    return url;
  }

  bool _isRunningOnNativePlatform() {
    try {
      return Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux;
    } catch (e) {
      return false;
    }
  }

  Future<QrCodeResult> getQrCode() async {
    try {
      final url = _getProxiedUrl('$_baseUrl/ilink/bot/get_bot_qrcode?bot_type=3');
      print('[WeChat] =======================================');
      print('[WeChat] 正在请求: $url');
      print('[WeChat] 请求方式: GET (与Python版本一致)');
      print('[WeChat] 请求时间: ${DateTime.now().toIso8601String()}');

      final response = await http.get(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      print('[WeChat] ---------------------------------------');
      print('[WeChat] 响应状态码: ${response.statusCode}');
      print('[WeChat] 响应头 Content-Type: ${response.headers['content-type']}');
      print('[WeChat] 响应体长度: ${utf8.decode(response.bodyBytes).length} 字符');
      print('[WeChat] 完整响应体:');
      print('[WeChat] ${utf8.decode(response.bodyBytes)}');
      print('[WeChat] ---------------------------------------');

      if (response.statusCode == 200) {
        dynamic data;
        try {
          data = jsonDecode(utf8.decode(response.bodyBytes));
          print('[WeChat] JSON 解析成功');
          print('[WeChat] 返回字段列表: ${(data is Map ? data.keys.toList() : "非Map类型")}');

          if (data is Map) {
            data.forEach((key, value) {
              final valueStr = value?.toString() ?? 'null';
              final displayValue = valueStr.length > 100
                  ? '${valueStr.substring(0, 100)}...(共${valueStr.length}字符)'
                  : valueStr;
              print('[WeChat]   字段 "$key": $displayValue');
            });
          }
        } catch (e) {
          print('[WeChat] JSON 解析失败: $e');
          throw Exception('响应不是有效的JSON格式。原始响应:\n${utf8.decode(response.bodyBytes)}');
        }

        if (data == null || (data is Map && data.isEmpty)) {
          throw Exception('服务器返回空对象 {}。完整响应:\n${utf8.decode(response.bodyBytes)}');
        }

        if (data is! Map) {
          throw Exception(
              '返回数据格式异常(期望Map, 实际${data.runtimeType})。内容: $data');
        }

        final qrcodeKey = data['qrcode']?.toString() ?? '';
        final qrcodeImageUrl = data['qrcode_img_content']?.toString() ?? '';

        print('[WeChat] =======================================');
        print('[WeChat] 解析结果汇总:');
        print('[WeChat]   - qrcodeKey: ${qrcodeKey.isNotEmpty ? "✅ 已获取(${qrcodeKey.length}字符)" : "❌ 空/缺失"}');
        print('[WeChat]     内容预览: ${qrcodeKey.length > 50 ? "${qrcodeKey.substring(0, 50)}..." : qrcodeKey}');
        print('[WeChat]   - qrcodeImageUrl: ${qrcodeImageUrl.isNotEmpty ? "✅ 已获取(${qrcodeImageUrl.length}字符)" : "❌ 空/缺失"}');
        print('[WeChat]     内容预览: ${qrcodeImageUrl.length > 80 ? "${qrcodeImageUrl.substring(0, 80)}..." : qrcodeImageUrl}');
        print('[WeChat] =======================================');

        return QrCodeResult(
          qrcodeKey: qrcodeKey,
          qrcodeImageUrl: qrcodeImageUrl,
        );
      }

      throw Exception(
          'HTTP 错误 ${response.statusCode}: ${response.reasonPhrase ?? "未知原因"}\n'
          '完整响应:\n${utf8.decode(response.bodyBytes)}');
    } on Exception catch (e) {
      print('[WeChat] ❌ 请求异常: $e');
      print('[WeChat] 异常时间: ${DateTime.now().toIso8601String()}');
      rethrow;
    }
  }

  Future<QrCodeStatus> checkQrCodeStatus(String qrCode) async {
    try {
      final encodedQr = Uri.encodeComponent(qrCode);
      print('[WeChat] 查询二维码状态: qrcode=$encodedQr');

      final response = await http.get(
        Uri.parse(_getProxiedUrl(
            '$_baseUrl/ilink/bot/get_qrcode_status?qrcode=$encodedQr')),
        headers: {
          'Content-Type': 'application/json',
          'iLink-App-ClientVersion': '1',
        },
      ).timeout(const Duration(seconds: 10));

      print('[WeChat] 状态查询响应5.10: ${response.statusCode} - ${utf8.decode(response.bodyBytes)}');

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        
        // 调试：打印所有字段和token值
        print('[WeChat] 📋 响应字段列表: ${data.keys.toList()}');
        final botTokenValue = data['bot_token'];
        final accessTokenValue = data['access_token'];
        final tokenValue = data['token'];
        print('[WeChat] 🔑 bot_token: $botTokenValue');
        print('[WeChat] 🔑 access_token: $accessTokenValue');
        print('[WeChat] 🔑 token: $tokenValue');
        
        final extractedToken = botTokenValue ?? accessTokenValue ?? tokenValue;
        print('[WeChat] ✅ 最终提取的token: ${extractedToken != null ? "${extractedToken.toString().substring(0, extractedToken.toString().length > 20 ? 20 : extractedToken.toString().length)}..." : "null"}');

        return QrCodeStatus(
          status: data['status'] ?? QrCodeStatus.error,
          message: data['message'],
          botId: data['ilink_bot_id'],
          userId: data['ilink_user_id'],
          token: extractedToken, // 从状态响应直接获取token
        );
      }
      throw Exception('查询状态失败: ${response.statusCode}');
    } catch (e) {
      throw Exception('查询状态异常: $e');
    }
  }

  Future<bool> loginWithQrCode(String qrCode) async {
    int attempts = 0;
    const maxAttempts = 60;

    while (attempts < maxAttempts) {
      await Future.delayed(const Duration(seconds: 2));
      attempts++;

      try {
        final status = await checkQrCodeStatus(qrCode);

        if (status.isConfirmed &&
            status.botId != null &&
            status.userId != null) {
          String? token;
          
          // 优先从状态响应中获取token（与Python版本一致）
          if (status.token != null && status.token!.isNotEmpty) {
            token = status.token;
            print('[WeChat] ✅ 从状态响应获取Token成功');
          } else {
            // Fallback：尝试调用login接口（可能已废弃）
            print('[WeChat] 状态响应无token，尝试login接口...');
            token = await _getToken(status.botId!, status.userId!);
          }

          if (token != null && token.isNotEmpty) {
            _credentials = WeChatCredentials(
              token: token,
              baseUrl: _baseUrl,
              botId: status.botId!,
              userId: status.userId!,
              createdAt: DateTime.now(),
            );
            return true;
          }
        }

        if (status.isExpired) {
          throw Exception('二维码已过期，请重新获取');
        }
      } catch (e) {
        if (e.toString().contains('过期')) rethrow;
      }
    }

    throw Exception('扫码超时，请重试');
  }

  Future<String?> _getToken(String botId, String userId) async {
    return await getTokenWithIds(botId, userId);
  }

  Future<String?> getTokenWithIds(String botId, String userId) async {
    print('[WeChat] 获取 Token, botId: $botId, userId: $userId');

    try {
      final response = await http.post(
        Uri.parse(_getProxiedUrl('$_baseUrl/ilink/bot/login')),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'bot_type': 3,
          'ilink_bot_id': botId,
          'ilink_user_id': userId,
        }),
      ).timeout(const Duration(seconds: 15));

      print('[WeChat] Token 响应状态码: ${response.statusCode}');
      print('[WeChat] Token 响应体: ${utf8.decode(response.bodyBytes)}');

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final token = data['access_token'] ?? data['token'];
        print('[WeChat] ✅ Token 获取成功: ${token != null ? "已获取(${token.length > 20 ? token.substring(0, 20) + "..." : token})" : "空"}');
        return token;
      }

      print('[WeChat] ❌ Token 获取失败: HTTP ${response.statusCode}');
      return null;
    } catch (e) {
      print('[WeChat] ❌ Token 获取异常: $e');
      return null;
    }
  }

  Future<List<WeChatMessage>> getUpdates() async {
    if (_credentials == null) return [];

    try {
      final response = await http.post(
        Uri.parse(_getProxiedUrl('$_baseUrl/ilink/bot/getupdates')),
        headers: {
          'Content-Type': 'application/json',
          'AuthorizationType': 'ilink_bot_token',
          'Authorization': 'Bearer ${_credentials!.token}',
          'X-WECHAT-UIN': CryptoUtils.generateRandomHex(16),
        },
        body: jsonEncode({
          'get_updates_buf': '',
          'base_info': {'channel_version': channelVersion},
        }),
      ).timeout(const Duration(seconds: 35));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final msgs = data['msgs'] as List? ?? [];

        return msgs.map((u) {
          final itemList = u['item_list'];
          final msg = WeChatMessage(
            messageId: u['message_id']?.toString() ?? '',
            fromUser: u['from_user_id'] ?? u['from_user'] ?? '',
            content: u['text'] ?? _extractTextFromItems(itemList),
            timestamp: u['create_time_ms'] != null
                ? DateTime.fromMillisecondsSinceEpoch(u['create_time_ms'])
                : DateTime.now(),
            messageType: _getMessageType(u),
            contextToken: u['context_token'],
            imageUrls: _extractImageUrls(itemList),
          );

          if (msg.contextToken != null && msg.contextToken!.isNotEmpty) {
            _contextTokens[msg.fromUser] = msg.contextToken!;
          }

          return msg;
        }).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  List<String> _extractImageUrls(dynamic itemList) {
    if (itemList == null || itemList is! List) return [];

    final urls = <String>[];
    for (final item in itemList) {
      if (item is Map && item['type'] == 2) {
        final imageItem = item['image_item'];
        if (imageItem is Map) {
          final possibleUrl = imageItem['thumb_url'] ?? imageItem['url'] ?? imageItem['cdn_url'] ?? imageItem['image_url'];
          if (possibleUrl != null && possibleUrl.toString().isNotEmpty) {
            urls.add(possibleUrl.toString());
          }
        }
        final media = item['media'];
        if (media is Map) {
          final possibleUrl = media['thumb_url'] ?? media['url'] ?? media['cdn_url'] ?? media['image_url'];
          if (possibleUrl != null && possibleUrl.toString().isNotEmpty) {
            urls.add(possibleUrl.toString());
          }
        }
      }
    }
    return urls;
  }

  String _extractTextFromItems(dynamic itemList) {
    if (itemList == null || itemList is! List) return '';

    final texts = <String>[];
    for (final item in itemList) {
      if (item is Map) {
        final type = item['type'];
        switch (type) {
          case 1:
            texts.add(item['text_item']?['text'] ?? '');
            break;
          case 2:
            texts.add('[图片]');
            break;
          case 3:
            final voiceText = item['voice_item']?['text'] ?? '';
            texts.add(voiceText.isNotEmpty ? voiceText : '[语音]');
            break;
          case 4:
            texts.add('[文件: ${item['file_item']?['file_name'] ?? ''}]');
            break;
          case 5:
            texts.add('[视频]');
            break;
        }
      }
    }
    return texts.join('\n');
  }

  String _getMessageType(Map<String, dynamic> msg) {
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

  Future<bool> sendMessage({
    required String toUser,
    required String content,
    String type = 'text',
  }) async {
    if (_credentials == null) return false;

    try {
      final ctxToken = _contextTokens[toUser];
      final clientId = CryptoUtils.generateRandomHex(32);

      final messageBody = {
        'from_user_id': '',
        'to_user_id': toUser,
        'client_id': clientId,
        'message_type': 2,
        'message_state': 3,
        'context_token': ctxToken ?? '',
        'item_list': [
          {
            'type': 1,
            'text_item': {'text': content},
          }
        ],
      };

      final response = await http.post(
        Uri.parse(_getProxiedUrl('$_baseUrl/ilink/bot/sendmessage')),
        headers: {
          'Content-Type': 'application/json',
          'AuthorizationType': 'ilink_bot_token',
          'Authorization': 'Bearer ${_credentials!.token}',
          'X-WECHAT-UIN': CryptoUtils.generateRandomHex(16),
        },
        body: jsonEncode({
          'msg': messageBody,
          'base_info': {'channel_version': channelVersion},
        }),
      ).timeout(const Duration(seconds: 15));

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> sendImage({
    required String toUser,
    required String imageUrl,
  }) async {
    if (_credentials == null) return false;

    try {
      Uint8List imageData;

      if (imageUrl.startsWith('http://') || imageUrl.startsWith('https://')) {
        imageData = await _downloadImage(imageUrl);
      } else {
        imageData = File(imageUrl).readAsBytesSync();
      }

      return await _doSendMedia(
        toUser: toUser,
        mediaData: imageData,
        mediaType: MediaType.image,
      );
    } catch (e) {
      print('[WeChat] ❌ 发送图片失败: $e');
      return false;
    }
  }

  Future<bool> sendVoice({
    required String toUser,
    required String voicePath,
    int durationMs = 5000,
  }) async {
    if (_credentials == null) return false;

    try {
      final voiceData = File(voicePath).readAsBytesSync();

      return await _doSendMedia(
        toUser: toUser,
        mediaData: voiceData,
        mediaType: MediaType.voice,
        extraParams: {'playtime': durationMs},
      );
    } catch (e) {
      print('[WeChat] ❌ 发送语音失败: $e');
      return false;
    }
  }

  Future<bool> sendFile({
    required String toUser,
    required String filePath,
    String? fileName,
  }) async {
    if (_credentials == null) return false;

    try {
      final fileData = File(filePath).readAsBytesSync();
      final actualName = fileName ?? path_lib.basename(filePath);

      return await _doSendMedia(
        toUser: toUser,
        mediaData: fileData,
        mediaType: MediaType.file,
        extraParams: {'file_name': actualName},
      );
    } catch (e) {
      print('[WeChat] ❌ 发送文件失败: $e');
      return false;
    }
  }

  Future<bool> sendVideo({
    required String toUser,
    required String videoPath,
    int? durationMs,
  }) async {
    if (_credentials == null) return false;

    try {
      final videoData = File(videoPath).readAsBytesSync();

      final params = <String, dynamic>{};
      if (durationMs != null) {
        params['play_length'] = durationMs;
      }

      return await _doSendMedia(
        toUser: toUser,
        mediaData: videoData,
        mediaType: MediaType.video,
        extraParams: params,
      );
    } catch (e) {
      print('[WeChat] ❌ 发送视频失败: $e');
      return false;
    }
  }

  Future<Uint8List> _downloadImage(String url) async {
    final response = await http.get(Uri.parse(url)).timeout(
      const Duration(seconds: 30),
    );

    if (response.statusCode != 200) {
      throw Exception('图片下载失败: HTTP ${response.statusCode}');
    }

    return response.bodyBytes;
  }

  Future<String?> downloadImageAsBase64(String imageUrl) async {
    try {
      final imageData = await _downloadImage(imageUrl);
      final mimeType = _guessMimeType(imageUrl, imageData);
      final base64Data = base64.encode(imageData);
      return 'data:$mimeType;base64,$base64Data';
    } catch (e) {
      print('[WeChat] 图片下载或编码失败: $e');
      return null;
    }
  }

  String _guessMimeType(String url, Uint8List data) {
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains('.png')) return 'image/png';
    if (lowerUrl.contains('.gif')) return 'image/gif';
    if (lowerUrl.contains('.webp')) return 'image/webp';
    if (lowerUrl.contains('.bmp')) return 'image/bmp';
    if (data.length > 3 && data[0] == 0xFF && data[1] == 0xD8) return 'image/jpeg';
    if (data.length > 3 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return 'image/png';
    if (data.length > 3 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return 'image/gif';
    return 'image/jpeg';
  }

  Future<bool> _doSendMedia({
    required String toUser,
    required Uint8List mediaData,
    required MediaType mediaType,
    Map<String, dynamic>? extraParams,
  }) async {
    final rawSize = mediaData.length;
    final rawMd5 = CryptoUtils.md5Hash(mediaData);
    final paddedSize = CryptoUtils.getPaddedSize(rawSize);
    final fileKey = CryptoUtils.generateRandomHex(16);
    final aesKeyHex = CryptoUtils.generateRandomHex(16);
    final aesKeyBytes = List.generate(
      16,
      (i) => int.parse(aesKeyHex.substring(i * 2, i * 2 + 2), radix: 16),
    );

    print('[WeChat] 开始上传媒体: type=${mediaType.name}, size=${(rawSize / 1024).toStringAsFixed(1)}KB');

    final uploadResult = await _getUploadUrl(
      toUser: toUser,
      fileKey: fileKey,
      mediaType: mediaType.value,
      rawsize: rawSize,
      rawfilemd5: rawMd5,
      filesize: paddedSize,
      aeskeyHex: aesKeyHex,
    );

    final uploadParam = uploadResult['upload_param'] ?? '';
    final cdnBaseUrl = uploadResult['cdn_base_url'] ?? '';

    print('[WeChat] 获取上传URL成功，开始加密...');

    final encryptedData = CryptoUtils.aesEcbEncrypt(mediaData, aesKeyBytes);

    print('[WeChat] 加密完成 (${encryptedData.length} bytes)，开始上传CDN...');

    final downloadParam = await _uploadToCdn(
      cdnBaseUrl: cdnBaseUrl,
      uploadParam: uploadParam,
      fileKey: fileKey,
      encryptedData: encryptedData,
    );

    if (downloadParam == null) {
      throw Exception('CDN上传失败');
    }

    print('[WeChat] CDN上传成功，构建消息体...');

    final aesKeyBase64 = CryptoUtils.generateBase64(aesKeyHex);

    final mediaObj = {
      'encrypt_query_param': downloadParam,
      'aes_key': aesKeyBase64,
      'encrypt_type': 1,
    };

    final itemType = _getMediaTypeForItem(mediaType);
    final itemBody = <String, dynamic>{'media': mediaObj};

    if (extraParams != null) {
      itemBody.addAll(extraParams);
    }

    if (mediaType == MediaType.image) {
      itemBody['mid_size'] = rawSize;
    }

    final ctxToken = _contextTokens[toUser];
    final clientId = CryptoUtils.generateRandomHex(32);

    final messageBody = {
      'from_user_id': '',
      'to_user_id': toUser,
      'client_id': clientId,
      'message_type': 2,
      'message_state': 3,
      'context_token': ctxToken ?? '',
      'item_list': [
        {
          'type': itemType,
          '${_getItemTypeName(itemType)}_item': itemBody,
        }
      ],
    };

    final response = await http.post(
      Uri.parse(_getProxiedUrl('$_baseUrl/ilink/bot/sendmessage')),
      headers: {
        'Content-Type': 'application/json',
        'AuthorizationType': 'ilink_bot_token',
        'Authorization': 'Bearer ${_credentials!.token}',
        'X-WECHAT-UIN': CryptoUtils.generateRandomHex(16),
      },
      body: jsonEncode({
        'msg': messageBody,
        'base_info': {'channel_version': channelVersion},
      }),
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      print('[WeChat] ✅ ${mediaType.name}发送成功!');
      return true;
    } else {
      print('[WeChat] ❌ ${mediaType.name}发送失败: ${response.statusCode}');
      return false;
    }
  }

  int _getMediaTypeForItem(MediaType type) {
    switch (type) {
      case MediaType.image:
        return 2;
      case MediaType.video:
        return 5;
      case MediaType.file:
        return 4;
      case MediaType.voice:
        return 3;
    }
  }

  String _getItemTypeName(int type) {
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
      default:
        return 'unknown';
    }
  }

  Future<Map<String, dynamic>> _getUploadUrl({
    required String toUser,
    required String fileKey,
    required int mediaType,
    required int rawsize,
    required String rawfilemd5,
    required int filesize,
    required String aeskeyHex,
  }) async {
    final response = await http.post(
      Uri.parse(_getProxiedUrl('$_baseUrl/ilink/bot/getuploadurl')),
      headers: {
        'Content-Type': 'application/json',
        'AuthorizationType': 'ilink_bot_token',
        'Authorization': 'Bearer ${_credentials!.token}',
        'X-WECHAT-UIN': CryptoUtils.generateRandomHex(16),
      },
      body: jsonEncode({
        'filekey': fileKey,
        'media_type': mediaType,
        'to_user_id': toUser,
        'rawsize': rawsize,
        'rawfilemd5': rawfilemd5,
        'filesize': filesize,
        'no_need_thumb': true,
        'aeskey': aeskeyHex,
        'base_info': {'channel_version': channelVersion},
      }),
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw Exception('获取上传URL失败: ${response.statusCode}');
  }

  Future<String?> _uploadToCdn({
    required String cdnBaseUrl,
    required String uploadParam,
    required String fileKey,
    required Uint8List encryptedData,
  }) async {
    final candidateUrls = <Map<String, String>>[];

    if (cdnBaseUrl.isNotEmpty) {
      var processedBase = cdnBaseUrl.replaceAll(RegExp(r'/$'), '');
      if (!processedBase.startsWith('http://') && !processedBase.startsWith('https://')) {
        processedBase = 'https://$processedBase';
      }
      candidateUrls.add({
        'url': '$processedBase/upload?encrypted_query_param=${Uri.encodeComponent(uploadParam)}&filekey=$fileKey',
        'source': '来自getuploadurl响应',
      });
    }

    if (uploadParam.startsWith('http://') ||
        uploadParam.startsWith('https://')) {
      candidateUrls.add({
        'url': '$uploadParam&filekey=$fileKey',
        'source': 'upload_param本身是完整URL',
      });
    }

    candidateUrls.add({
      'url':
          'https://novac2c.cdn.weixin.qq.com/c2c/upload?encrypted_query_param=${Uri.encodeComponent(uploadParam)}&filekey=$fileKey',
      'source': '备选节点',
    });

    Exception? lastError;

    for (final entry in candidateUrls) {
      final url = entry['url']!;
      final source = entry['source']!;

      try {
        print('[WeChat] 尝试上传到CDN ($source): ${url.length > 80 ? "${url.substring(0, 80)}..." : url}');

        final response = await http.post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/octet-stream'},
          body: encryptedData,
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode >= 400 && response.statusCode < 500) {
          final errorMsg = response.headers['x-error-message'] ??
              'HTTP ${response.statusCode}';
          throw Exception('CDN客户端错误: $errorMsg');
        }

        if (response.statusCode != 200) {
          final errorMsg = response.headers['x-error-message'] ??
              'HTTP ${response.statusCode}';
          lastError = Exception('CDN服务器错误: $errorMsg');
          continue;
        }

        final downloadParam = response.headers['x-encrypted-param'];
        if (downloadParam != null && downloadParam.isNotEmpty) {
          print('[WeChat] ✅ CDN上传成功');
          return downloadParam;
        }

        lastError = Exception('CDN上传响应缺少x-encrypted-param头');
      } catch (e) {
        print('[WeChat] ⚠️ CDN上传失败 ($source): $e');
        lastError = e is Exception ? e : Exception(e.toString());
      }
    }

    throw lastError ?? Exception('CDN上传失败: 所有节点均不可用');
  }

  Map<String, dynamic> _buildBaseInfo() {
    return {'channel_version': channelVersion};
  }

  Future<Map<String, dynamic>?> getConfig(String toUser) async {
    if (_credentials == null) return null;
    final ctxToken = _contextTokens[toUser];
    if (ctxToken == null) return null;
    try {
      final response = await http.post(
        Uri.parse(_getProxiedUrl('$_baseUrl/ilink/bot/getconfig')),
        headers: {
          'Content-Type': 'application/json',
          'AuthorizationType': 'ilink_bot_token',
          'Authorization': 'Bearer ${_credentials!.token}',
        },
        body: jsonEncode({
          'ilink_user_id': toUser,
          'context_token': ctxToken,
          'base_info': _buildBaseInfo(),
        }),
      ).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _sendTyping(String toUser, String ticket, int status) async {
    if (_credentials == null) return false;
    try {
      final response = await http.post(
        Uri.parse(_getProxiedUrl('$_baseUrl/ilink/bot/sendtyping')),
        headers: {
          'Content-Type': 'application/json',
          'AuthorizationType': 'ilink_bot_token',
          'Authorization': 'Bearer ${_credentials!.token}',
        },
        body: jsonEncode({
          'ilink_user_id': toUser,
          'typing_ticket': ticket,
          'status': status,
          'base_info': _buildBaseInfo(),
        }),
      ).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> showTyping(String toUser) async {
    final config = await getConfig(toUser);
    if (config == null) return false;
    final ticket = config['typing_ticket'] as String?;
    if (ticket == null || ticket.isEmpty) return false;
    return await _sendTyping(toUser, ticket, 1);
  }

  Future<bool> hideTyping(String toUser) async {
    final config = await getConfig(toUser);
    if (config == null) return false;
    final ticket = config['typing_ticket'] as String?;
    if (ticket == null || ticket.isEmpty) return false;
    return await _sendTyping(toUser, ticket, 2);
  }

  Future<void> disconnect() async {
    _credentials = null;
    _contextTokens.clear();
  }

  Map<String, dynamic>? exportCredentials() {
    return _credentials?.toJson();
  }

  void importCredentials(Map<String, dynamic> json) {
    _credentials = WeChatCredentials.fromJson(json);
  }
}
