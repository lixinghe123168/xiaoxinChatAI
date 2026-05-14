import 'dart:typed_data';

class SkillStorageService {
  static SkillStorageService? _instance;
  factory SkillStorageService() => _instance ??= SkillStorageService._();
  SkillStorageService._();

  final Map<String, Uint8List> _files = {};

  Future<String> copyFileToStorage(String sourcePath, String targetName) async {
    throw Exception('Web 不支持路径复制');
  }

  Future<String> writeBytesToStorage(Uint8List bytes, String targetName) async {
    _files[targetName] = bytes;
    return 'web://$targetName';
  }

  Future<String> readFileContent(String fileName) async {
    final bytes = _files[fileName];
    if (bytes == null) {
      throw Exception('文件不存在: $fileName');
    }
    return String.fromCharCodes(bytes);
  }

  Future<bool> deleteAllSkillFiles() async {
    _files.clear();
    return true;
  }

  Future<bool> fileExists(String fileName) async => _files.containsKey(fileName);
}