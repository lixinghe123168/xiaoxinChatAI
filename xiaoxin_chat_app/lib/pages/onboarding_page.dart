import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../app_theme.dart';
import '../models/app_config.dart';
import '../providers/app_provider.dart';

class OnboardingPage extends StatefulWidget {
  final Future<void> Function() onComplete;
  const OnboardingPage({super.key, required this.onComplete});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pageController = PageController();
  int _currentStep = 0;

  final _modelNameController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();

  final _emojiApiUrlController = TextEditingController();
  final _emojiApiIdController = TextEditingController();
  final _emojiApiKeyController = TextEditingController();

  bool _emojiEnabled = true;
  double _emojiProbability = 0.5;
  bool _voiceEnabled = true;
  bool _proactiveEnabled = true;
  int _proactiveInterval = 5;
  int _proactiveMaxIdle = 10;

  bool _shortTermEnabled = true;
  int _shortTermMax = 20;
  bool _longTermEnabled = true;
  int _retrievalTopK = 5;

  bool _modelVerified = false;
  bool _isVerifying = false;
  StreamSubscription? _intentDataStreamSubscription;

  @override
  void initState() {
    super.initState();
    _initShareIntentListener();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final config = context.read<AppProvider>().config;
      _modelNameController.text = config.model.name.isNotEmpty ? config.model.name : 'deepseek-chat';
      _apiKeyController.text = config.model.apiKey;
      _baseUrlController.text = config.model.baseUrl.isNotEmpty ? config.model.baseUrl : 'https://api.deepseek.com';
      _emojiApiUrlController.text = config.features.emojiApi.apiUrl;
      _emojiApiIdController.text = config.features.emojiApi.apiId;
      _emojiApiKeyController.text = config.features.emojiApi.apiKey;
    });
  }

  @override
  void dispose() {
    _intentDataStreamSubscription?.cancel();
    _pageController.dispose();
    _modelNameController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _emojiApiUrlController.dispose();
    _emojiApiIdController.dispose();
    _emojiApiKeyController.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_currentStep < 3) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _verifyModel() async {
    if (_modelNameController.text.trim().isEmpty || _apiKeyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写模型名称和 API Key'), backgroundColor: AppTheme.errorColor),
      );
      return;
    }

    setState(() => _isVerifying = true);

    try {
      final provider = context.read<AppProvider>();
      await provider.updateModelConfig(ModelConfig(
        name: _modelNameController.text,
        apiKey: _apiKeyController.text,
        baseUrl: _baseUrlController.text,
      ));
      final success = await provider.testLlmConnection();

      if (mounted) {
        setState(() {
          _isVerifying = false;
          _modelVerified = success;
        });

        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('验证通过！模型连接成功'), backgroundColor: AppTheme.successColor),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('验证失败，请检查配置信息'), backgroundColor: AppTheme.errorColor),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isVerifying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('验证失败: $e'), backgroundColor: AppTheme.errorColor),
        );
      }
    }
  }

  bool get _llmCompleted => _modelVerified;

  bool _skillCompleted(AppProvider provider) => provider.config.skill.isComplete;

  bool get _canProceed {
    if (_currentStep == 0) return _llmCompleted;
    if (_currentStep == 2) {
      final provider = context.read<AppProvider>();
      return _skillCompleted(provider);
    }
    if (_currentStep == 3) {
      final provider = context.read<AppProvider>();
      return _llmCompleted && _skillCompleted(provider);
    }
    return true;
  }

  Future<void> _finishOnboarding() async {
    final provider = context.read<AppProvider>();

    await provider.updateModelConfig(ModelConfig(
      name: _modelNameController.text,
      apiKey: _apiKeyController.text,
      baseUrl: _baseUrlController.text,
    ));

    await provider.updateFeaturesConfig(FeaturesConfig(
      emoji: _emojiEnabled,
      emojiProbability: _emojiProbability,
      emojiApi: EmojiApiConfig(
        apiUrl: _emojiApiUrlController.text,
        apiId: _emojiApiIdController.text,
        apiKey: _emojiApiKeyController.text,
      ),
      proactiveMessage: ProactiveMessageConfig(
        enabled: _proactiveEnabled,
        intervalMinutes: _proactiveInterval,
        maxIdleMinutes: _proactiveMaxIdle,
      ),
      voiceReply: _voiceEnabled,
      typingIndicator: true,
    ));

    await provider.updateMemoryConfig(MemoryConfig(
      shortTermEnabled: _shortTermEnabled,
      shortTermMax: _shortTermMax,
      longTermEnabled: _longTermEnabled,
      retrievalTopK: _retrievalTopK,
    ));

    if (mounted) {
      widget.onComplete();
    }
  }

  void _pickSkillFile(String fileName, void Function(String path) onDone) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: kIsWeb,
      );
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.single;
        final provider = context.read<AppProvider>();
        String? imported;
        String? errorMsg;

        try {
          if (!kIsWeb && file.path != null && file.path!.isNotEmpty) {
            imported = await provider.importSkillFile(file.path!, fileName);
          } else if (file.bytes != null) {
            imported = await provider.importSkillFileFromBytes(file.bytes!, fileName);
          } else {
            errorMsg = '无法读取文件内容';
          }
        } catch (e) {
          errorMsg = '写入失败: $e';
        }

        if (mounted) {
          if (imported != null) {
            onDone(file.name);
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$fileName 已导入'),
                behavior: SnackBarBehavior.floating,
                backgroundColor: AppTheme.successColor,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(errorMsg ?? '$fileName 导入失败，请重试'),
                behavior: SnackBarBehavior.floating,
                backgroundColor: AppTheme.errorColor,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败: $e'), backgroundColor: AppTheme.errorColor),
        );
      }
    }
  }

  void _initShareIntentListener() {
    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> files) {
      if (files.isNotEmpty) {
        _handleSharedFile(files.first.path);
      }
    });
  }

  void _handleSharedFile(String filePath) {
    final fileName = filePath.split('/').last.split('\\').last.toLowerCase();
    if (!fileName.contains('config.yaml') && !fileName.contains('persona.md') && !fileName.contains('memories.md')) return;

    final provider = context.read<AppProvider>();
    provider.importSkillFile(filePath, fileName).then((result) {
      if (result != null && mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$fileName 已导入'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        return SafeArea(
          child: Scaffold(
            backgroundColor: AppTheme.backgroundColor,
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      const Text(
                        '欢迎使用 xiaoxinChatAI',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                      ),
                      const Spacer(),
                      if (_currentStep > 0)
                        TextButton(
                          onPressed: () {
                            _pageController.jumpToPage(0);
                          },
                          child: Text('返回首页', style: TextStyle(color: AppTheme.primaryColor)),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (i) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: _currentStep == i ? 28 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _currentStep == i ? AppTheme.primaryColor : AppTheme.dividerColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) => setState(() => _currentStep = i),
                    children: [
                      _buildStep1(),
                      _buildStep2(),
                      _buildStep3(),
                      _buildStep4(),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _canProceed
                          ? (_currentStep < 3 ? _nextStep : _finishOnboarding)
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppTheme.dividerColor,
                        disabledForegroundColor: AppTheme.textSecondary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        _canProceed
                            ? (_currentStep < 3 ? '下一步' : '开始使用')
                            : (_currentStep == 0 ? '请填写模型信息' : (_currentStep == 2 ? '请导入全部三个文件' : '请先完成必需配置')),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _stepHeader(IconData icon, String title, String subtitle) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(icon, size: 36, color: AppTheme.primaryColor),
        ),
        const SizedBox(height: 20),
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
        const SizedBox(height: 8),
        Text(subtitle, textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary.withOpacity(0.8)),
        ),
      ],
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    IconData? icon,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon != null ? Icon(icon, size: 20) : null,
        ),
      ),
    );
  }

  Widget _buildToggleRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary))),
          Switch(value: value, onChanged: onChanged, activeColor: AppTheme.primaryColor),
        ],
      ),
    );
  }

  Widget _buildStep1() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _stepHeader(Icons.psychology_rounded, 'LLM 模型配置', '填写大语言模型的 API 信息'),
          const SizedBox(height: 28),
          _buildInputField(
            controller: _modelNameController,
            label: '模型名称',
            hint: 'deepseek-chat / gpt-4o',
            icon: Icons.psychology_rounded,
          ),
          _buildInputField(
            controller: _apiKeyController,
            label: 'API Key',
            hint: 'sk-xxxxxxxxxxxxxxxx',
            obscure: true,
            icon: Icons.key_rounded,
          ),
          _buildInputField(
            controller: _baseUrlController,
            label: 'API 地址',
            hint: 'https://api.deepseek.com',
            icon: Icons.link_rounded,
          ),
          const SizedBox(height: 20),
          if (_modelVerified)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.successColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.successColor.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.check_circle, size: 20, color: AppTheme.successColor),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text('模型连接验证通过', style: TextStyle(fontSize: 14, color: AppTheme.successColor, fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _isVerifying ? null : _verifyModel,
                icon: _isVerifying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.flash_on_rounded, size: 20),
                label: Text(_isVerifying ? '正在验证...' : '验证模型连接'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.dividerColor,
                  disabledForegroundColor: AppTheme.textSecondary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStep2() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _stepHeader(Icons.tune_rounded, '功能配置', '设置 AI 机器人的核心功能'),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.dividerColor),
            ),
            child: Column(
              children: [
                _buildToggleRow('发送表情包', _emojiEnabled, (v) => setState(() => _emojiEnabled = v)),
                if (_emojiEnabled) ...[
                  const Divider(),
                  _buildInputField(
                    controller: _emojiApiUrlController,
                    label: '表情包 API 地址',
                    hint: 'https://api.example.com/emoji',
                    icon: Icons.link_rounded,
                  ),
                  _buildInputField(
                    controller: _emojiApiIdController,
                    label: 'API ID',
                    hint: 'your_api_id',
                    icon: Icons.fingerprint,
                  ),
                  _buildInputField(
                    controller: _emojiApiKeyController,
                    label: 'API Key',
                    hint: 'your_api_key',
                    obscure: true,
                    icon: Icons.key_rounded,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.dividerColor),
            ),
            child: Column(
              children: [
                _buildToggleRow('启用语音回复', _voiceEnabled, (v) => setState(() => _voiceEnabled = v)),
                const Divider(),
                _buildToggleRow('主动发送消息', _proactiveEnabled, (v) => setState(() => _proactiveEnabled = v)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.successColor.withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.successColor.withOpacity(0.15)),
            ),
            child: Row(
              children: [
                Icon(Icons.lightbulb_outline, size: 18, color: AppTheme.successColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('更多高级设置可在设置页面的"功能"Tab中调整',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep3() {
    final skill = context.read<AppProvider>().config.skill;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _stepHeader(Icons.person_rounded, 'Skill 人设配置', '导入 AI 角色设定文件'),
          const SizedBox(height: 28),
          _buildSkillSlot('config.yaml', '人设配置（名称、描述、系统提示词、回复风格）',
            skill.configYamlPath.isNotEmpty, () => _pickSkillFile('config.yaml', (_) => setState(() {}))),
          _buildSkillSlot('persona.md', '详细人设设定',
            skill.personaMdPath.isNotEmpty, () => _pickSkillFile('persona.md', (_) => setState(() {}))),
          _buildSkillSlot('memories.md', '背景记忆库',
            skill.memoriesMdPath.isNotEmpty, () => _pickSkillFile('memories.md', (_) => setState(() {}))),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.primaryColor.withOpacity(0.15)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: AppTheme.primaryColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('三个文件全部导入后 Skill 配置才算完成。\n可在微信中收到文件后用"其他应用打开"选择 xiaoxinChatAI 快速导入',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkillSlot(String fileName, String description, bool imported, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: imported ? AppTheme.successColor.withOpacity(0.4) : AppTheme.dividerColor,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: imported ? AppTheme.successColor.withOpacity(0.1) : AppTheme.primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  imported ? Icons.check_circle : Icons.upload_file,
                  color: imported ? AppTheme.successColor : AppTheme.primaryColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(fileName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                    const SizedBox(height: 3),
                    Text(description, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
              Text(imported ? '已导入' : '点击导入',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: imported ? AppTheme.successColor : AppTheme.primaryColor)),
              const SizedBox(width: 4),
              Icon(imported ? Icons.check : Icons.chevron_right, size: 18, color: imported ? AppTheme.successColor : AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep4() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _stepHeader(Icons.memory_rounded, '记忆配置', '对话上下文和长期记忆管理'),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.dividerColor),
            ),
            child: Column(
              children: [
                _buildToggleRow('启用短期记忆', _shortTermEnabled,
                  (v) => setState(() => _shortTermEnabled = v)),
                if (_shortTermEnabled) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Expanded(child: Text('最大轮数', style: TextStyle(fontSize: 15, color: AppTheme.textPrimary))),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 160,
                          child: Slider(
                            value: _shortTermMax.toDouble(),
                            min: 5,
                            max: 50,
                            divisions: 9,
                            label: '$_shortTermMax 轮',
                            onChanged: (v) => setState(() => _shortTermMax = v.toInt()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.dividerColor),
            ),
            child: Column(
              children: [
                _buildToggleRow('启用长期记忆', _longTermEnabled,
                  (v) => setState(() => _longTermEnabled = v)),
                if (_longTermEnabled) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Expanded(child: Text('检索返回数', style: TextStyle(fontSize: 15, color: AppTheme.textPrimary))),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 160,
                          child: Slider(
                            value: _retrievalTopK.toDouble(),
                            min: 3,
                            max: 15,
                            divisions: 12,
                            label: '$_retrievalTopK 条',
                            onChanged: (v) => setState(() => _retrievalTopK = v.toInt()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.successColor.withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.successColor.withOpacity(0.15)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle_outline, size: 18, color: AppTheme.successColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('配置完成！点击"开始使用"即可进入应用。\n所有配置项后续可在设置页面中调整',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}