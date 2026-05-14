import 'package:flutter/foundation.dart';
import 'dart:typed_data';
import '../models/app_config.dart';
import '../models/chat_models.dart';
import '../core/bot_service.dart';
import '../core/wechat_client.dart';
import '../core/skill_storage.dart';
import '../utils/background_service.dart';

class AppProvider with ChangeNotifier {
  final BotService _botService = BotService();
  BotService get botService => _botService;
  final SkillStorageService _skillStorage = SkillStorageService();

  AppConfig _config = AppConfig(
    model: ModelConfig(),
    skill: SkillConfig(),
    memory: MemoryConfig(),
    tools: ToolsConfig(),
    features: FeaturesConfig(),
    system: SystemConfig(),
  );
  AppConfig get config => _config;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  List<ChatMessage> _chatMessages = [];
  List<ChatMessage> get chatMessages => _chatMessages;

  WeChatConnectionStatus _wechatStatus = WeChatConnectionStatus();
  WeChatConnectionStatus get wechatStatus => _wechatStatus;

  bool _isSendingMessage = false;
  bool get isSendingMessage => _isSendingMessage;

  Map<String, dynamic>? _memoryStats;
  Map<String, dynamic>? get memoryStats => _memoryStats;

  Future<void> initialize() async {
    if (_isInitialized) return;

    _isLoading = true;
    notifyListeners();

    try {
      await _botService.init();
      _config = _botService.config;
      _chatMessages = List.from(_botService.chatHistory);
      _isInitialized = true;

      if (_botService.isWechatConnected) {
        BackgroundService.start();

        _wechatStatus = _wechatStatus.copyWith(
          isConnected: true,
          userId: _botService.userId,
          statusMessage: '已连接',
        );
      }
    } catch (e) {
      print('[AppProvider] 初始化异常: $e');
      _errorMessage = '初始化失败: $e';
    }

    _isLoading = false;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<bool> saveAllConfig() async {
    return await _botService.saveConfig(_config);
  }

  Future<void> updateModelConfig(ModelConfig model) async {
    await _botService.updateModelConfig(model);
    _config = _botService.config;
    notifyListeners();
  }

  Future<void> updateSkillConfig(SkillConfig skill) async {
    await _botService.updateSkillConfig(skill);
    _config = _botService.config;
    notifyListeners();
  }

  Future<String?> importSkillFile(String sourcePath, String fileName) async {
    try {
      final savedPath = await _skillStorage.copyFileToStorage(sourcePath, fileName);
      return _applySkillFile(fileName, savedPath);
    } catch (e) {
      return null;
    }
  }

  Future<String?> importSkillFileFromBytes(Uint8List bytes, String fileName) async {
    try {
      final savedPath = await _skillStorage.writeBytesToStorage(bytes, fileName);
      return _applySkillFile(fileName, savedPath);
    } catch (e) {
      return null;
    }
  }

  Future<String?> _applySkillFile(String fileName, String savedPath) async {
    final newSkill = SkillConfig(
      configYamlPath: _config.skill.configYamlPath,
      personaMdPath: _config.skill.personaMdPath,
      memoriesMdPath: _config.skill.memoriesMdPath,
      enabled: _config.skill.enabled,
    );

    final lowerName = fileName.toLowerCase();
    String? matched;
    if (lowerName.contains('config.yaml')) {
      newSkill.configYamlPath = savedPath;
      matched = 'config.yaml';
    } else if (lowerName.contains('persona.md')) {
      newSkill.personaMdPath = savedPath;
      matched = 'persona.md';
    } else if (lowerName.contains('memories.md')) {
      newSkill.memoriesMdPath = savedPath;
      matched = 'memories.md';
    }
    if (matched == null) return null;

    if (newSkill.isComplete && !newSkill.enabled) {
      newSkill.enabled = true;
    }

    await _botService.updateSkillConfig(newSkill);
    _config = _botService.config;
    notifyListeners();
    return matched;
  }

  Future<bool> clearSkill() async {
    final deleted = await _skillStorage.deleteAllSkillFiles();
    await _botService.updateSkillConfig(SkillConfig());
    _config = _botService.config;
    notifyListeners();
    return deleted;
  }

  Future<void> updateMemoryConfig(MemoryConfig memory) async {
    await _botService.updateMemoryConfig(memory);
    _config = _botService.config;
    notifyListeners();
  }

  Future<void> updateToolsConfig(ToolsConfig tools) async {
    await _botService.updateToolsConfig(tools);
    _config = _botService.config;
    notifyListeners();
  }

  Future<void> updateFeaturesConfig(FeaturesConfig features) async {
    await _botService.updateFeaturesConfig(features);
    _config = _botService.config;
    notifyListeners();
  }

  Future<void> updateSystemConfig(SystemConfig system) async {
    await _botService.updateSystemConfig(system);
    _config = _botService.config;
    notifyListeners();
  }

  Future<void> sendMessage(String message) async {
    if (message.trim().isEmpty || _isSendingMessage) return;

    _isSendingMessage = true;
    notifyListeners();

    final response = await _botService.sendUserMessage(message);

    _isSendingMessage = false;
    
    if (response != null) {
      _chatMessages = List.from(_botService.chatHistory);
    }
    
    notifyListeners();
  }

  Future<String> getWechatQrCode() async {
    try {
      final result = await _botService.getWechatQrCode();

      if (result.qrcodeImageUrl.isEmpty && result.qrcodeKey.isEmpty) {
        _errorMessage = '微信服务器返回空数据\n\n可能原因:\n'
            '- 服务暂时不可用\n'
            '- 网络连接问题\n'
            '- API 地址配置错误\n'
            '- 需要认证或权限';
        notifyListeners();
        throw Exception(_errorMessage);
      }

      if (result.qrcodeImageUrl.isEmpty) {
        final debugInfo = [
          'qrcodeKey: ${result.qrcodeKey.isNotEmpty ? "已获取(${result.qrcodeKey.length}字符)" : "空"}',
          if (result.qrcodeKey.isNotEmpty) 'qrcodeKey内容: ${result.qrcodeKey.length > 100 ? result.qrcodeKey.substring(0, 100) + "..." : result.qrcodeKey}',
        ].join('\n');

        _errorMessage = '未获取到登录链接\n\nAPI 返回详情:\n$debugInfo\n\n'
            '可能原因:\n'
            '- API 返回格式变更\n'
            '- qrcode_img_content 字段缺失\n'
            '- 服务器返回非URL数据';
        notifyListeners();
        throw Exception(_errorMessage);
      }

      _wechatStatus = _wechatStatus.copyWith(
        isConnecting: true,
        qrcodeImageUrl: result.qrcodeImageUrl,
        qrcodeKey: result.qrcodeKey,
        statusMessage: '请使用微信扫码',
      );
      notifyListeners();
      return result.qrcodeImageUrl;
    } catch (e) {
      final errorStr = e.toString();
      
      if (_errorMessage == null || _errorMessage!.isEmpty) {
        if (errorStr.contains('HTTP 错误') || 
            errorStr.contains('完整响应') ||
            errorStr.contains('原始响应')) {
          _errorMessage = errorStr;
        } else {
          _errorMessage = '连接微信服务器失败\n\n详细信息:\n$errorStr\n\n'
              '请检查:\n'
              '- 手机网络连接\n'
              '- API 地址是否正确\n'
              '- 是否需要VPN/代理';
        }
      }
      print('[AppProvider] 最终错误信息: $_errorMessage');
      notifyListeners();
      rethrow;
    }
  }

  Future<void> loginWechat(String qrCodeData) async {
    _wechatStatus = _wechatStatus.copyWith(isConnecting: true, statusMessage: '等待扫码...');
    notifyListeners();

    try {
      final success = await _botService.loginWechat(
        _wechatStatus.qrcodeKey ?? qrCodeData,
      );

      if (success) {
        await BackgroundService.start();

        _wechatStatus = WeChatConnectionStatus(
          isConnected: true,
          userId: _botService.userId,
          statusMessage: '连接成功',
        );
      } else {
        _wechatStatus = _wechatStatus.copyWith(
          isConnecting: false,
          statusMessage: '连接失败',
        );
      }
    } catch (e) {
      _wechatStatus = _wechatStatus.copyWith(
        isConnecting: false,
        statusMessage: e.toString().replaceAll('Exception: ', ''),
      );
    }

    notifyListeners();
  }

  Future<void> disconnectWechat() async {
    await BackgroundService.stop();
    await _botService.disconnectWechat();
    _wechatStatus = WeChatConnectionStatus(statusMessage: '已断开');
    notifyListeners();
  }

  Future<QrCodeStatus> pollWechatStatus() async {
    final qrcodeKey = _wechatStatus.qrcodeKey;
    
    if (qrcodeKey == null || qrcodeKey.isEmpty) {
      throw Exception('qrcodeKey 为空，无法轮询');
    }

    print('[AppProvider] 轮询微信状态, qrcodeKey: ${qrcodeKey.length > 20 ? "${qrcodeKey.substring(0, 20)}..." : qrcodeKey}');

    try {
      final status = await _botService.pollWechatQrCodeStatus(qrcodeKey);
      
      print('[AppProvider] 轮询返回 - status: ${status.status}, message: "${status.message}", botId: ${status.botId}, userId: ${status.userId}');
      
      if (status.isConfirmed) {
        _wechatStatus = _wechatStatus.copyWith(
          isConnecting: false,
          statusMessage: '扫码成功，正在登录...',
        );
      } else if (status.isScanned) {
        _wechatStatus = _wechatStatus.copyWith(
          statusMessage: '已扫码，请在手机确认',
        );
      } else if (status.isExpired) {
        _wechatStatus = _wechatStatus.copyWith(
          isConnecting: false,
          statusMessage: '二维码已过期',
        );
      } else {
        _wechatStatus = _wechatStatus.copyWith(
          statusMessage: '等待扫码...',
        );
      }
      
      notifyListeners();
      return status;
    } catch (e) {
      print('[AppProvider] 轮询异常: $e');
      rethrow;
    }
  }

  Future<void> completeWechatLogin(QrCodeStatus status) async {
    print('[AppProvider] 完成微信登录, botId: ${status.botId}, userId: ${status.userId}');
    
    try {
      _wechatStatus = _wechatStatus.copyWith(
        isConnecting: true,
        statusMessage: '正在获取凭证...',
      );
      notifyListeners();

      final success = await _botService.loginWithCredentials(
        botId: status.botId ?? '',
        userId: status.userId ?? '',
        token: status.token, // 传入从状态响应获取的token
      );

      if (success) {
        await BackgroundService.start();
        
        _wechatStatus = WeChatConnectionStatus(
          isConnected: true,
          userId: _botService.userId,
          statusMessage: '连接成功',
        );
        
        print('[AppProvider] ✅ 微信登录完成！');
      } else {
        _wechatStatus = _wechatStatus.copyWith(
          isConnecting: false,
          statusMessage: '登录失败，请重试',
        );
      }
    } catch (e) {
      print('[AppProvider] 登录异常: $e');
      _wechatStatus = _wechatStatus.copyWith(
        isConnecting: false,
        statusMessage: '登录失败: $e',
      );
    }

    notifyListeners();
  }

  Future<void> loadMemoryStats() async {
    _memoryStats = await _botService.getMemoryStats();
    notifyListeners();
  }

  Future<bool> clearAllMemory() async {
    return await _botService.clearAllMemories();
  }

  Future<bool> clearChatHistory() async {
    final success = await _botService.clearChatHistory();
    if (success) {
      _chatMessages.clear();
      notifyListeners();
    }
    return success;
  }

  Future<bool> testLlmConnection() async {
    return await _botService.testLlmConnection();
  }

  @override
  void dispose() {
    _botService.dispose();
    super.dispose();
  }
}
