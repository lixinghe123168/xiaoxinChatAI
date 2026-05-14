enum MessageType { user, bot, system }

class ChatMessage {
  final String id;
  final String content;
  final MessageType type;
  final DateTime timestamp;
  final String? emojiKeyword;
  final int? latencyMs;
  final bool? memoryHit;
  final List<String>? toolCalls;

  ChatMessage({
    required this.id,
    required this.content,
    required this.type,
    DateTime? timestamp,
    this.emojiKeyword,
    this.latencyMs,
    this.memoryHit,
    this.toolCalls,
  }) : timestamp = timestamp ?? DateTime.now();

  factory ChatMessage.user(String content, {String? id}) {
    return ChatMessage(
      id: id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      type: MessageType.user,
    );
  }

  factory ChatMessage.bot(
    String content, {
    String? id,
    String? emojiKeyword,
    int? latencyMs,
    bool? memoryHit,
    List<String>? toolCalls,
  }) {
    return ChatMessage(
      id: id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      type: MessageType.bot,
      emojiKeyword: emojiKeyword,
      latencyMs: latencyMs,
      memoryHit: memoryHit,
      toolCalls: toolCalls,
    );
  }

  factory ChatMessage.system(String content) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      type: MessageType.system,
    );
  }
}

class WeChatConnectionStatus {
  final bool isConnected;
  final bool isConnecting;
  final String? qrcodeImageUrl;
  final String? qrcodeKey;
  final String? statusMessage;
  final String? userId;

  WeChatConnectionStatus({
    this.isConnected = false,
    this.isConnecting = false,
    this.qrcodeImageUrl,
    this.qrcodeKey,
    this.statusMessage,
    this.userId,
  });

  WeChatConnectionStatus copyWith({
    bool? isConnected,
    bool? isConnecting,
    String? qrcodeImageUrl,
    String? qrcodeKey,
    String? statusMessage,
    String? userId,
  }) {
    return WeChatConnectionStatus(
      isConnected: isConnected ?? this.isConnected,
      isConnecting: isConnecting ?? this.isConnecting,
      qrcodeImageUrl: qrcodeImageUrl ?? this.qrcodeImageUrl,
      qrcodeKey: qrcodeKey ?? this.qrcodeKey,
      statusMessage: statusMessage ?? this.statusMessage,
      userId: userId ?? this.userId,
    );
  }
}
