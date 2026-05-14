import 'dart:convert';
import 'package:http/http.dart' as http;

class LlmContentPart {
  final String type;
  final String? text;
  final String? imageUrl;

  const LlmContentPart.text(String text)
      : type = 'text',
        text = text,
        imageUrl = null;

  const LlmContentPart.imageUrl(String imageUrl)
      : type = 'image_url',
        text = null,
        imageUrl = imageUrl;

  Map<String, dynamic> toJson() {
    if (type == 'text') {
      return {'type': 'text', 'text': text};
    } else {
      return {
        'type': 'image_url',
        'image_url': {'url': imageUrl},
      };
    }
  }
}

class LlmChatMessage {
  final String role;
  final dynamic content;
  final String? toolCalls;
  final String? toolCallId;

  const LlmChatMessage({
    required this.role,
    required this.content,
    this.toolCalls,
    this.toolCallId,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content is String ? content : (content as List<LlmContentPart>).map((p) => p.toJson()).toList(),
        if (toolCalls != null) 'tool_calls': toolCalls,
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

class LlmResponse {
  final String content;
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final List<ToolCall>? toolCalls;

  const LlmResponse({
    required this.content,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.toolCalls,
  });
}

class ToolCall {
  final String id;
  final String name;
  final String arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    return ToolCall(
      id: json['id'] ?? '',
      name: json['function']['name'] ?? '',
      arguments: json['function']['arguments']?.toString() ?? '{}',
    );
  }
}

class LlmApiClient {
  String baseUrl = '';
  String apiKey = '';
  String model = '';
  double temperature = 0.7;
  int maxTokens = 2000;
  int timeoutSeconds = 120;

  void configure({
    required String baseUrl,
    required String apiKey,
    required String model,
    double temperature = 0.7,
    int maxTokens = 2000,
    int timeoutSeconds = 120,
  }) {
    this.baseUrl = baseUrl.replaceAll(RegExp(r'/$'), '');
    this.apiKey = apiKey;
    this.model = model;
    this.temperature = temperature;
    this.maxTokens = maxTokens;
    this.timeoutSeconds = timeoutSeconds;
  }

  bool get isConfigured =>
      baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;

  Future<LlmResponse> chat({
    required List<LlmChatMessage> messages,
    List<Map<String, dynamic>>? tools,
  }) async {
    if (!isConfigured) {
      throw Exception('LLM API 未配置');
    }

    final url = Uri.parse('$baseUrl/v1/chat/completions');

    final body = <String, dynamic>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': temperature,
      'max_tokens': maxTokens,
    };

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(body),
          )
          .timeout(Duration(seconds: timeoutSeconds));

      if (response.statusCode == 200) {
        return _parseResponse(jsonDecode(utf8.decode(response.bodyBytes)));
      } else {
        throw Exception('API 错误 ${response.statusCode}: ${utf8.decode(response.bodyBytes)}');
      }
    } catch (e) {
      throw Exception('请求失败: $e');
    }
  }

  LlmResponse _parseResponse(Map<String, dynamic> json) {
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('无效响应：无 choices');
    }

    final choice = choices[0];
    final message = choice['message'] as Map<String, dynamic>? ?? {};

    List<ToolCall>? parsedToolCalls;
    if (message['tool_calls'] != null) {
      parsedToolCalls = (message['tool_calls'] as List)
          .map((t) => ToolCall.fromJson(t))
          .toList();
    }

    final usage = json['usage'];

    return LlmResponse(
      content: message['content'] ?? '',
      finishReason: choice['finish_reason'],
      promptTokens: usage?['prompt_tokens'],
      completionTokens: usage?['completion_tokens'],
      totalTokens: usage?['total_tokens'],
      toolCalls: parsedToolCalls,
    );
  }

  Future<bool> testConnection() async {
    if (!isConfigured) return false;

    try {
      final url = Uri.parse('$baseUrl/v1/models');
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $apiKey'},
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
