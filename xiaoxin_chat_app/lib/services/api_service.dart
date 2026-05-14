import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/app_config.dart';
import '../models/chat_models.dart';

class ApiService {
  static const String defaultBaseUrl = 'http://127.0.0.1:8501';
  String _baseUrl = defaultBaseUrl;

  String get baseUrl => _baseUrl;

  void setBaseUrl(String url) {
    _baseUrl = url;
  }

  Future<bool> checkConnection() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/_stcore/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<AppConfig?> fetchConfig() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/config'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json is Map<String, dynamic>) {
          return AppConfig.fromJson(json);
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<bool> updateConfig(AppConfig config) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/config'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(config.toJson()),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<List<ChatMessage>?> fetchChatHistory() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/chat/history'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(response.body);
        return jsonList.map((json) {
          final typeStr = json['type'] ?? 'bot';
          final type = typeStr == 'user'
              ? MessageType.user
              : typeStr == 'system'
                  ? MessageType.system
                  : MessageType.bot;
          return ChatMessage(
            id: json['id'] ?? '',
            content: json['content'] ?? '',
            type: type,
            timestamp: json['timestamp'] != null
                ? DateTime.parse(json['timestamp'])
                : DateTime.now(),
            emojiKeyword: json['emoji_keyword'],
            latencyMs: json['latency_ms'],
            memoryHit: json['memory_hit'],
            toolCalls: json['tool_calls'] != null
                ? List<String>.from(json['tool_calls'])
                : null,
          );
        }).toList();
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<ChatMessage?> sendMessage(String message) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/chat/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'message': message}),
      ).timeout(const Duration(seconds: 120));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return ChatMessage.bot(
          json['response'] ?? '',
          id: json['id'],
          emojiKeyword: json['emoji_keyword'],
          latencyMs: json['latency_ms'],
          memoryHit: json['memory_hit'],
          toolCalls: json['tool_calls'] != null
              ? List<String>.from(json['tool_calls'])
              : null,
        );
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getWechatStatus() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/wechat/status'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> connectWechat() async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/wechat/connect'),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<bool> disconnectWechat() async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/wechat/disconnect'),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> getMemoryStats() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/memory/stats'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<bool> clearMemory() async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/memory/clear'),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<bool> clearChatHistory() async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/chat/clear'),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}
