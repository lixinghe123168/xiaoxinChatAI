import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class SkillStorageService {
  static SkillStorageService? _instance;
  factory SkillStorageService() => _instance ??= SkillStorageService._();
  SkillStorageService._();

  Future<String> get _skillDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'skill_files'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<String> copyFileToStorage(String sourcePath, String targetName) async {
    final dirPath = await _skillDir;
    final targetPath = p.join(dirPath, targetName);
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw Exception('源文件不存在: $sourcePath');
    }
    await sourceFile.copy(targetPath);
    return targetPath;
  }

  Future<String> writeBytesToStorage(Uint8List bytes, String targetName) async {
    final dirPath = await _skillDir;
    final targetPath = p.join(dirPath, targetName);
    final file = File(targetPath);
    await file.writeAsBytes(bytes);
    return targetPath;
  }

  Future<String> readFileContent(String fileName) async {
    final dirPath = await _skillDir;
    final file = File(p.join(dirPath, fileName));
    if (!await file.exists()) {
      throw Exception('文件不存在: $fileName');
    }
    return await file.readAsString();
  }

  Future<bool> deleteAllSkillFiles() async {
    try {
      final dirPath = await _skillDir;
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> fileExists(String fileName) async {
    final dirPath = await _skillDir;
    return await File(p.join(dirPath, fileName)).exists();
  }
}