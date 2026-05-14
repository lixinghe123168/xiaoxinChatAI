import 'skill_storage.dart';
import '../models/app_config.dart';

class SkillData {
  final String name;
  final String systemPrompt;
  final String persona;
  final String memories;

  SkillData({
    this.name = '小欣',
    this.systemPrompt = '',
    this.persona = '',
    this.memories = '',
  });

  bool get hasConfig => systemPrompt.isNotEmpty;
  bool get hasPersona => persona.isNotEmpty;
  bool get hasMemories => memories.isNotEmpty;
  bool get isComplete => hasConfig || hasPersona || hasMemories;
}

class SkillLoader {
  static SkillLoader? _instance;
  factory SkillLoader() => _instance ??= SkillLoader._();
  SkillLoader._();

  Future<SkillData> load(SkillConfig config) async {
    if (!config.enabled) return SkillData();

    try {
      final storage = SkillStorageService();
      String? configContent;
      String? personaContent;
      String? memoriesContent;

      if (config.configYamlPath.isNotEmpty) {
        configContent = await storage.readFileContent(config.configYamlPath);
      }
      if (config.personaMdPath.isNotEmpty) {
        personaContent = await storage.readFileContent(config.personaMdPath);
      }
      if (config.memoriesMdPath.isNotEmpty) {
        memoriesContent = await storage.readFileContent(config.memoriesMdPath);
      }

      return _parseContent(configContent, personaContent, memoriesContent);
    } catch (e) {
      print('[SkillLoader] 加载失败: $e');
      return SkillData();
    }
  }

  SkillData _parseContent(String? configContent, String? personaContent, String? memoriesContent) {
    var name = '小欣';
    var systemPrompt = '';

    if (configContent != null && configContent.isNotEmpty) {
      final lines = configContent.split('\n')
          .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#'))
          .toList();
      final raw = lines.join('\n');

      final nameMatch = RegExp(r'name_zh:\s*(.+)').firstMatch(raw);
      if (nameMatch != null) {
        name = nameMatch.group(1)!.trim();
      }

      final promptMatch = RegExp(r'system_prompt:\s*\|\s*\n(.+?)(?=\n\w|\Z)', dotAll: true).firstMatch(raw);
      if (promptMatch != null) {
        systemPrompt = promptMatch.group(1)!.trim();
      }
    }

    return SkillData(
      name: name,
      systemPrompt: systemPrompt,
      persona: personaContent ?? '',
      memories: memoriesContent ?? '',
    );
  }
}
