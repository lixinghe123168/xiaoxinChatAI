import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../app_theme.dart';
import '../models/app_config.dart';
import '../providers/app_provider.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final _modelNameController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _emojiApiUrlController = TextEditingController();
  final _emojiApiIdController = TextEditingController();
  final _emojiApiKeyController = TextEditingController();
  final _appNameController = TextEditingController();
  XFile? _selectedIconFile;
  String? _savedIconPath;
  StreamSubscription? _intentDataStreamSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadConfig();
      _loadCustomAppConfig();
    });
    _initShareIntentListener();
  }

  @override
  void dispose() {
    _intentDataStreamSubscription?.cancel();
    _tabController.dispose();
    _modelNameController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _emojiApiUrlController.dispose();
    _emojiApiIdController.dispose();
    _emojiApiKeyController.dispose();
    _appNameController.dispose();
    super.dispose();
  }

  void _initShareIntentListener() {
    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> files) {
      if (files.isNotEmpty) {
        _handleSharedFile(files.first.path);
      }
    });
  }

  void _handleSharedFile(String filePath) {
    final fileName = filePath.split('/').last.split('\\').last;
    if (!fileName.toLowerCase().contains('config.yaml') &&
        !fileName.toLowerCase().contains('persona.md') &&
        !fileName.toLowerCase().contains('memories.md')) return;

    final provider = context.read<AppProvider>();
    provider.importSkillFile(filePath, fileName).then((result) {
      if (result != null && mounted) {
        _tabController.animateTo(1);
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

  void _loadConfig() {
    final provider = context.read<AppProvider>();
    final config = provider.config;

    _modelNameController.text = config.model.name;
    _apiKeyController.text = config.model.apiKey;
    _baseUrlController.text = config.model.baseUrl;
    _emojiApiUrlController.text = config.features.emojiApi.apiUrl;
    _emojiApiIdController.text = config.features.emojiApi.apiId;
    _emojiApiKeyController.text = config.features.emojiApi.apiKey;
  }

  Future<void> _saveConfig() async {
    final provider = context.read<AppProvider>();

    await provider.updateModelConfig(ModelConfig(
      name: _modelNameController.text,
      apiKey: _apiKeyController.text,
      baseUrl: _baseUrlController.text,
    ));

    await provider.updateFeaturesConfig(FeaturesConfig(
      emoji: provider.config.features.emoji,
      emojiProbability: provider.config.features.emojiProbability,
      emojiApi: EmojiApiConfig(
        apiUrl: _emojiApiUrlController.text,
        apiId: _emojiApiIdController.text,
        apiKey: _emojiApiKeyController.text,
      ),
      maxMessages: provider.config.features.maxMessages,
      proactiveMessage: provider.config.features.proactiveMessage,
      fileReply: provider.config.features.fileReply,
      videoReply: provider.config.features.videoReply,
      voiceReply: provider.config.features.voiceReply,
      typingIndicator: provider.config.features.typingIndicator,
      imageHandling: provider.config.features.imageHandling,
    ));

    final prefs = await SharedPreferences.getInstance();
    final oldName = prefs.getString('custom_app_name') ?? '';
    final oldIconPath = prefs.getString('custom_app_icon_path');
    final nameChanged = oldName != _appNameController.text;

    bool iconChanged = false;
    if (_selectedIconFile != null) {
      final bytes = await _selectedIconFile!.readAsBytes();
      final dir = await getApplicationDocumentsDirectory();
      final iconFile = File('${dir.path}/custom_app_icon.png');
      await iconFile.writeAsBytes(bytes);
      await prefs.setString('custom_app_icon_path', iconFile.path);
      iconChanged = true;
    } else if (nameChanged && _appNameController.text.isEmpty && oldIconPath != null) {
      await prefs.remove('custom_app_icon_path');
      final dir = await getApplicationDocumentsDirectory();
      final iconFile = File('${dir.path}/custom_app_icon.png');
      if (iconFile.existsSync()) {
        await iconFile.delete();
      }
    }

    await prefs.setString('custom_app_name', _appNameController.text);

    final appDisplayChanged = nameChanged || iconChanged || _selectedIconFile != null;

    if (mounted) {
      if (appDisplayChanged && Platform.isAndroid) {
        const channel = MethodChannel('com.xiaoxinchat.xiaoxin_chat_app/restart');
        final iconPath = prefs.getString('custom_app_icon_path');

        await channel.invokeMethod('setAppDisplay', {
          'label': _appNameController.text,
          'iconPath': iconPath,
        });

        final shortcutSupported = await channel.invokeMethod('isShortcutSupported') as bool;

        if (shortcutSupported) {
          await channel.invokeMethod('createHomeShortcut', {
            'label': _appNameController.text,
            'iconPath': iconPath,
          });
        }

        if (mounted) {
          final msg = StringBuffer();
          msg.writeln('自定义图标和名称已保存！');
          msg.writeln('');
          msg.writeln('📱 最近任务列表图标已更新');
          if (shortcutSupported) {
            msg.writeln('📌 请查看系统弹出的"添加到桌面"对话框');
            msg.writeln('   点击"添加"后可在桌面看到自定义图标');
          } else {
            msg.writeln('⚠️ 您的桌面启动器不支持添加快捷方式');
            msg.writeln('   图标变更仅在最近任务中可见');
          }
          msg.writeln('');
          msg.writeln('重启应用后完全生效，是否现在重启？');

          final shouldRestart = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('保存成功'),
              content: Text(msg.toString()),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('稍后重启'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('立即重启'),
                ),
              ],
            ),
          );

          if (shouldRestart == true && mounted && Platform.isAndroid) {
            const channel = MethodChannel('com.xiaoxinchat.xiaoxin_chat_app/restart');
            await channel.invokeMethod('restartApp');
          }
        }
      } else if (Platform.isAndroid) {
        const channel = MethodChannel('com.xiaoxinchat.xiaoxin_chat_app/restart');
        final iconPath = prefs.getString('custom_app_icon_path');
        await channel.invokeMethod('setAppDisplay', {
          'label': _appNameController.text,
          'iconPath': iconPath,
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('配置已保存'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppTheme.successColor,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('配置已保存'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppTheme.successColor,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Future<void> _pickSkillFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: kIsWeb,
      );
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.single;
        final fileName = file.name;
        final provider = context.read<AppProvider>();
        String? imported;
        if (!kIsWeb && file.path != null && file.path!.isNotEmpty) {
          imported = await provider.importSkillFile(file.path!, fileName);
        } else if (file.bytes != null) {
          imported = await provider.importSkillFileFromBytes(file.bytes!, fileName);
        }
        if (imported != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$fileName 已导入'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppTheme.successColor,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('选择文件失败: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  Future<void> _loadCustomAppConfig() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _appNameController.text = prefs.getString('custom_app_name') ?? '';
      _savedIconPath = prefs.getString('custom_app_icon_path');
    });
  }

  Future<void> _pickAppIcon() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
    );
    if (file != null && mounted) {
      setState(() {
        _selectedIconFile = file;
      });
    }
  }

  void _confirmClearSkill() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除 Skill'),
        content: const Text('确定要清除当前所有 Skill 配置文件吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              final provider = context.read<AppProvider>();
              provider.clearSkill().then((_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Skill 已清除'),
                      behavior: SnackBarBehavior.floating,
                      backgroundColor: AppTheme.successColor,
                    ),
                  );
                }
              });
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
            child: const Text('确定清除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          backgroundColor: AppTheme.backgroundColor,
          appBar: AppBar(
            bottom: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabs: const [
                Tab(text: '模型'),
                Tab(text: 'Skill'),
                Tab(text: '记忆'),
                Tab(text: '功能'),
                Tab(text: '系统'),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildModelTab(provider),
                    _buildSkillTab(provider),
                    _buildMemoryTab(provider),
                    _buildFeaturesTab(provider),
                    _buildSystemTab(provider),
                  ],
                ),
              ),
              _buildSaveButton(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionTitle(String title, {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textSecondary.withOpacity(0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscureText = false,
    IconData? prefixIcon,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 20) : null,
        ),
      ),
    );
  }

  Widget _buildSwitch({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(title),
      subtitle: subtitle != null
          ? Text(subtitle, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
          : null,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: AppTheme.primaryColor,
      ),
    );
  }

  Widget _buildSlider({
    required String title,
    required double value,
    required double min,
    required double max,
    int? divisions,
    String? suffix,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(title)),
          const SizedBox(width: 12),
          SizedBox(
            width: 180,
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: suffix ?? value.toStringAsFixed(2),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelTab(AppProvider provider) {
    return ListView(
      children: [
        _buildSectionTitle('LLM API 配置', subtitle: '填写大模型 API 信息'),
        _buildTextField(
          controller: _modelNameController,
          label: '模型名称',
          hint: 'deepseek-chat / gpt-4o',
          prefixIcon: Icons.psychology_rounded,
        ),
        _buildTextField(
          controller: _apiKeyController,
          label: 'API Key',
          hint: 'sk-xxxxxxxxxxxxxxxx',
          obscureText: true,
          prefixIcon: Icons.key_rounded,
        ),
        _buildTextField(
          controller: _baseUrlController,
          label: 'API 地址',
          hint: 'https://api.deepseek.com',
          prefixIcon: Icons.link_rounded,
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(20),
          child: OutlinedButton.icon(
            onPressed: () async {
              final success = await provider.testLlmConnection();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success ? '连接成功!' : '连接失败，请检查配置'),
                    behavior: SnackBarBehavior.floating,
                    backgroundColor:
                        success ? AppTheme.successColor : AppTheme.errorColor,
                  ),
                );
              }
            },
            icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
            label: const Text('测试连接'),
          ),
        ),
      ],
    );
  }

  Widget _buildSkillTab(AppProvider provider) {
    final skill = provider.config.skill;
    return ListView(
      children: [
        _buildSectionTitle('Skill 人设', subtitle: '需导入三个配置文件'),
        _buildSwitch(
          title: '启用 Skill',
          subtitle: skill.isComplete ? '全部就绪，可正常使用' : '缺少文件，Skill 未完成配置',
          value: skill.enabled,
          onChanged: (v) => provider.updateSkillConfig(SkillConfig(
            configYamlPath: skill.configYamlPath,
            personaMdPath: skill.personaMdPath,
            memoriesMdPath: skill.memoriesMdPath,
            enabled: v,
          )),
        ),
        const SizedBox(height: 8),
        _buildSkillFileSlot(
          fileName: 'config.yaml',
          description: '人设配置（名称、描述、系统提示词、回复风格）',
          isImported: skill.configYamlPath.isNotEmpty,
          onTap: () => _pickSkillFile(),
        ),
        _buildSkillFileSlot(
          fileName: 'persona.md',
          description: '详细人设设定',
          isImported: skill.personaMdPath.isNotEmpty,
          onTap: () => _pickSkillFile(),
        ),
        _buildSkillFileSlot(
          fileName: 'memories.md',
          description: '背景记忆库',
          isImported: skill.memoriesMdPath.isNotEmpty,
          onTap: () => _pickSkillFile(),
        ),
        if (skill.isComplete) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.successColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.successColor.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: AppTheme.successColor, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    '全部就绪，Skill 配置已完成',
                    style: TextStyle(color: AppTheme.successColor, fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: OutlinedButton.icon(
              onPressed: _confirmClearSkill,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('清除 Skill'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.errorColor,
                side: const BorderSide(color: AppTheme.errorColor),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSkillFileSlot({
    required String fileName,
    required String description,
    required bool isImported,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isImported
                  ? AppTheme.successColor.withOpacity(0.4)
                  : AppTheme.dividerColor,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isImported
                      ? AppTheme.successColor.withOpacity(0.1)
                      : AppTheme.primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isImported ? Icons.check_circle : Icons.upload_file,
                  color: isImported ? AppTheme.successColor : AppTheme.primaryColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                isImported ? '已导入' : '点击导入',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isImported ? AppTheme.successColor : AppTheme.primaryColor,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                isImported ? Icons.check : Icons.chevron_right,
                size: 18,
                color: isImported ? AppTheme.successColor : AppTheme.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMemoryTab(AppProvider provider) {
    WidgetsBinding.instance.addPostFrameCallback((_) => provider.loadMemoryStats());
    final memory = provider.config.memory;
    return ListView(
      children: [
        _buildSectionTitle('短期记忆', subtitle: '对话上下文管理'),
        _buildSwitch(
          title: '启用短期记忆',
          value: memory.shortTermEnabled,
          onChanged: (v) => provider.updateMemoryConfig(MemoryConfig(
            shortTermEnabled: v,
            shortTermMax: memory.shortTermMax,
            longTermEnabled: memory.longTermEnabled,
            longTermMax: memory.longTermMax,
            expireDays: memory.expireDays,
            retrievalTopK: memory.retrievalTopK,
            retrievalMinScore: memory.retrievalMinScore,
          )),
        ),
        _buildSlider(
          title: '最大轮数',
          value: memory.shortTermMax.toDouble(),
          min: 5,
          max: 50,
          divisions: 9,
          suffix: '${memory.shortTermMax} 轮',
          onChanged: (v) => provider.updateMemoryConfig(MemoryConfig(
            shortTermEnabled: memory.shortTermEnabled,
            shortTermMax: v.toInt(),
            longTermEnabled: memory.longTermEnabled,
            longTermMax: memory.longTermMax,
            expireDays: memory.expireDays,
            retrievalTopK: memory.retrievalTopK,
            retrievalMinScore: memory.retrievalMinScore,
          )),
        ),
        const Divider(height: 1),
        Consumer<AppProvider>(
          builder: (_, p, __) {
            final count = p.memoryStats?['total_count'];
            return _buildSectionTitle(
              count != null ? '长期记忆（$count 条）' : '长期记忆',
              subtitle: '持久化存储与检索',
            );
          },
        ),
        _buildSwitch(
          title: '启用长期记忆',
          value: memory.longTermEnabled,
          onChanged: (v) => provider.updateMemoryConfig(MemoryConfig(
            shortTermEnabled: memory.shortTermEnabled,
            shortTermMax: memory.shortTermMax,
            longTermEnabled: v,
            longTermMax: memory.longTermMax,
            expireDays: memory.expireDays,
            retrievalTopK: memory.retrievalTopK,
            retrievalMinScore: memory.retrievalMinScore,
          )),
        ),
        _buildSlider(
          title: '过期天数',
          value: memory.expireDays.toDouble(),
          min: 30,
          max: 180,
          divisions: 10,
          suffix: '${memory.expireDays} 天',
          onChanged: (v) => provider.updateMemoryConfig(MemoryConfig(
            shortTermEnabled: memory.shortTermEnabled,
            shortTermMax: memory.shortTermMax,
            longTermEnabled: memory.longTermEnabled,
            longTermMax: memory.longTermMax,
            expireDays: v.toInt(),
            retrievalTopK: memory.retrievalTopK,
            retrievalMinScore: memory.retrievalMinScore,
          )),
        ),
        _buildSlider(
          title: '检索返回数',
          value: memory.retrievalTopK.toDouble(),
          min: 3,
          max: 15,
          divisions: 12,
          suffix: '${memory.retrievalTopK} 条',
          onChanged: (v) => provider.updateMemoryConfig(MemoryConfig(
            shortTermEnabled: memory.shortTermEnabled,
            shortTermMax: memory.shortTermMax,
            longTermEnabled: memory.longTermEnabled,
            longTermMax: memory.longTermMax,
            expireDays: memory.expireDays,
            retrievalTopK: v.toInt(),
            retrievalMinScore: memory.retrievalMinScore,
          )),
        ),
        const SizedBox(height: 8),
        Consumer<AppProvider>(
          builder: (context, p, _) => SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _confirmClearMemory(context, p),
              icon: const Icon(Icons.delete_forever_rounded, size: 18, color: Color(0xFFE53935)),
              label: const Text('删除所有长期记忆', style: TextStyle(color: Color(0xFFE53935))),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFE53935)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearMemory(BuildContext context, AppProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('是否删除所有长期记忆\n\n该操作不可撤销'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFE53935)),
            child: const Text('删除', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await provider.clearAllMemory();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('长期记忆已全部删除'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Widget _buildFeaturesTab(AppProvider provider) {
    final features = provider.config.features;
    return ListView(
      children: [
        _buildSectionTitle('表情包', subtitle: 'AI 回复附带表情'),
        _buildSwitch(
          title: '发送表情包',
          value: features.emoji,
          onChanged: (v) => provider.updateFeaturesConfig(FeaturesConfig(
            emoji: v,
            emojiProbability: features.emojiProbability,
            emojiApi: features.emojiApi,
            maxMessages: features.maxMessages,
            proactiveMessage: features.proactiveMessage,
            fileReply: features.fileReply,
            videoReply: features.videoReply,
            voiceReply: features.voiceReply,
            typingIndicator: features.typingIndicator,
            imageHandling: features.imageHandling,
          )),
        ),
        if (features.emoji) ...[
          _buildSlider(
            title: '发送概率',
            value: features.emojiProbability,
            min: 0,
            max: 1,
            divisions: 10,
            suffix: '${(features.emojiProbability * 100).toInt()}%',
            onChanged: (v) => provider.updateFeaturesConfig(FeaturesConfig(
              emoji: features.emoji,
              emojiProbability: v,
              emojiApi: features.emojiApi,
              maxMessages: features.maxMessages,
              proactiveMessage: features.proactiveMessage,
              fileReply: features.fileReply,
              videoReply: features.videoReply,
              voiceReply: features.voiceReply,
              typingIndicator: features.typingIndicator,
              imageHandling: features.imageHandling,
            )),
          ),
          _buildTextField(
            controller: _emojiApiUrlController,
            label: 'API 地址',
            hint: 'https://api.example.com/emoji',
            prefixIcon: Icons.link_rounded,
          ),
          _buildTextField(
            controller: _emojiApiIdController,
            label: 'API ID',
            hint: 'your_api_id',
            prefixIcon: Icons.fingerprint,
          ),
          _buildTextField(
            controller: _emojiApiKeyController,
            label: 'API Key',
            hint: 'your_api_key',
            obscureText: true,
            prefixIcon: Icons.key_rounded,
          ),
        ],
        const Divider(height: 1),
        _buildSectionTitle('主动消息', subtitle: 'AI 主动发起对话'),
        _buildSwitch(
          title: '启用主动消息',
          value: features.proactiveMessage.enabled,
          onChanged: (v) => provider.updateFeaturesConfig(FeaturesConfig(
            emoji: features.emoji,
            emojiProbability: features.emojiProbability,
            emojiApi: features.emojiApi,
            maxMessages: features.maxMessages,
            proactiveMessage: ProactiveMessageConfig(
              enabled: v,
              intervalMinutes: features.proactiveMessage.intervalMinutes,
              maxIdleMinutes: features.proactiveMessage.maxIdleMinutes,
              probability: features.proactiveMessage.probability,
            ),
            fileReply: features.fileReply,
            videoReply: features.videoReply,
            voiceReply: features.voiceReply,
            typingIndicator: features.typingIndicator,
            imageHandling: features.imageHandling,
          )),
        ),
        if (features.proactiveMessage.enabled) ...[
          _buildSlider(
            title: '检查间隔（分钟）',
            value: features.proactiveMessage.intervalMinutes.toDouble(),
            min: 1,
            max: 60,
            divisions: 59,
            suffix: '${features.proactiveMessage.intervalMinutes} 分钟',
            onChanged: (v) => provider.updateFeaturesConfig(FeaturesConfig(
              emoji: features.emoji,
              emojiProbability: features.emojiProbability,
              emojiApi: features.emojiApi,
              maxMessages: features.maxMessages,
              proactiveMessage: ProactiveMessageConfig(
                enabled: features.proactiveMessage.enabled,
                intervalMinutes: v.toInt(),
                maxIdleMinutes: features.proactiveMessage.maxIdleMinutes,
                probability: features.proactiveMessage.probability,
              ),
              fileReply: features.fileReply,
              videoReply: features.videoReply,
              voiceReply: features.voiceReply,
              typingIndicator: features.typingIndicator,
              imageHandling: features.imageHandling,
            )),
          ),
          _buildSlider(
            title: '最大空闲（分钟）',
            value: features.proactiveMessage.maxIdleMinutes.toDouble(),
            min: 1,
            max: 120,
            divisions: 119,
            suffix: '${features.proactiveMessage.maxIdleMinutes} 分钟',
            onChanged: (v) => provider.updateFeaturesConfig(FeaturesConfig(
              emoji: features.emoji,
              emojiProbability: features.emojiProbability,
              emojiApi: features.emojiApi,
              maxMessages: features.maxMessages,
              proactiveMessage: ProactiveMessageConfig(
                enabled: features.proactiveMessage.enabled,
                intervalMinutes: features.proactiveMessage.intervalMinutes,
                maxIdleMinutes: v.toInt(),
                probability: features.proactiveMessage.probability,
              ),
              fileReply: features.fileReply,
              videoReply: features.videoReply,
              voiceReply: features.voiceReply,
              typingIndicator: features.typingIndicator,
              imageHandling: features.imageHandling,
            )),
          ),
        ],
        const Divider(height: 1),
        _buildSectionTitle('其他功能'),
        _buildSwitch(
          title: '启用语音',
          subtitle: 'AI 能够理解你的语音并回答',
          value: features.voiceReply,
          onChanged: (v) => provider.updateFeaturesConfig(FeaturesConfig(
            emoji: features.emoji,
            emojiProbability: features.emojiProbability,
            emojiApi: features.emojiApi,
            maxMessages: features.maxMessages,
            proactiveMessage: features.proactiveMessage,
            fileReply: features.fileReply,
            videoReply: features.videoReply,
            voiceReply: v,
            typingIndicator: features.typingIndicator,
            imageHandling: features.imageHandling,
          )),
        ),
        _buildSwitch(
          title: '打字状态指示',
          value: features.typingIndicator,
          onChanged: (v) => provider.updateFeaturesConfig(FeaturesConfig(
            emoji: features.emoji,
            emojiProbability: features.emojiProbability,
            emojiApi: features.emojiApi,
            maxMessages: features.maxMessages,
            proactiveMessage: features.proactiveMessage,
            fileReply: features.fileReply,
            videoReply: features.videoReply,
            voiceReply: features.voiceReply,
            typingIndicator: v,
            imageHandling: features.imageHandling,
          )),
        ),
      ],
    );
  }

  Widget _buildAppIconPicker() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: GestureDetector(
        onTap: _pickAppIcon,
        child: Row(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppTheme.surfaceColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: _buildIconPreview(),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '应用图标',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _selectedIconFile != null
                        ? '已选择新图标'
                        : (_savedIconPath != null ? '点击更换图标' : '点击选择图标'),
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary.withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.camera_alt_outlined, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildIconPreview() {
    if (_selectedIconFile != null) {
      return Image.file(File(_selectedIconFile!.path), fit: BoxFit.cover);
    }
    if (_savedIconPath != null && File(_savedIconPath!).existsSync()) {
      return Image.file(File(_savedIconPath!), fit: BoxFit.cover);
    }
    return Container(
      color: AppTheme.primaryColor.withOpacity(0.1),
      child: const Icon(Icons.android_rounded, size: 36, color: AppTheme.primaryColor),
    );
  }

  Widget _buildSystemTab(AppProvider provider) {
    final system = provider.config.system;
    return ListView(
      children: [
        _buildSectionTitle('应用外观', subtitle: '自定义应用图标和名称'),
        _buildAppIconPicker(),
        _buildTextField(
          controller: _appNameController,
          label: '应用名称',
          hint: '输入自定义应用名称',
          prefixIcon: Icons.edit_rounded,
        ),
        const Divider(height: 1),
        _buildSectionTitle('生成参数', subtitle: 'LLM 回复控制'),
        _buildSlider(
          title: 'Temperature',
          value: system.temperature,
          min: 0,
          max: 2,
          divisions: 20,
          suffix: system.temperature.toStringAsFixed(2),
          onChanged: (v) => provider.updateSystemConfig(SystemConfig(
            temperature: v,
            maxTokens: system.maxTokens,
            timeout: system.timeout,
          )),
        ),
        _buildSlider(
          title: '超时时间（秒）',
          value: system.timeout.toDouble(),
          min: 30,
          max: 300,
          divisions: 27,
          suffix: '${system.timeout}s',
          onChanged: (v) => provider.updateSystemConfig(SystemConfig(
            temperature: system.temperature,
            maxTokens: system.maxTokens,
            timeout: v.toInt(),
          )),
        ),
        const Divider(height: 1),
        // _buildSectionTitle('联网工具'),
        // _buildSwitch(
        //   title: '网页搜索',
        //   value: provider.config.tools.webSearch,
        //   onChanged: (v) => provider.updateToolsConfig(ToolsConfig(
        //     webSearch: v,
        //     webSearchSource: provider.config.tools.webSearchSource,
        //   )),
        // ),
      ],
    );
  }

  Widget _buildSaveButton() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            offset: const Offset(0, -2),
            blurRadius: 6,
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: _saveConfig,
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 48),
        ),
        child: const Text('保存配置'),
      ),
    );
  }
}
