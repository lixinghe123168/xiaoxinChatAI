class AppConfig {
  final ModelConfig model;
  final SkillConfig skill;
  final MemoryConfig memory;
  final ToolsConfig tools;
  final FeaturesConfig features;
  final SystemConfig system;

  AppConfig({
    required this.model,
    required this.skill,
    required this.memory,
    required this.tools,
    required this.features,
    required this.system,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      model: ModelConfig.fromJson(json['model'] ?? {}),
      skill: SkillConfig.fromJson(json['skill'] ?? {}),
      memory: MemoryConfig.fromJson(json['memory'] ?? {}),
      tools: ToolsConfig.fromJson(json['tools'] ?? {}),
      features: FeaturesConfig.fromJson(json['features'] ?? {}),
      system: SystemConfig.fromJson(json['system'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'model': model.toJson(),
        'skill': skill.toJson(),
        'memory': memory.toJson(),
        'tools': tools.toJson(),
        'features': features.toJson(),
        'system': system.toJson(),
      };
}

class ModelConfig {
  String name;
  String apiKey;
  String baseUrl;

  ModelConfig({
    this.name = '',
    this.apiKey = '',
    this.baseUrl = '',
  });

  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    return ModelConfig(
      name: json['name'] ?? '',
      apiKey: json['api_key'] ?? '',
      baseUrl: json['base_url'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'api_key': apiKey,
        'base_url': baseUrl,
      };

  bool get isConfigured => name.isNotEmpty && apiKey.isNotEmpty && baseUrl.isNotEmpty;
}

class SkillConfig {
  String configYamlPath;
  String personaMdPath;
  String memoriesMdPath;
  bool enabled;

  SkillConfig({
    this.configYamlPath = '',
    this.personaMdPath = '',
    this.memoriesMdPath = '',
    this.enabled = true,
  });

  bool get isComplete =>
      configYamlPath.isNotEmpty &&
      personaMdPath.isNotEmpty &&
      memoriesMdPath.isNotEmpty;

  factory SkillConfig.fromJson(Map<String, dynamic> json) {
    return SkillConfig(
      configYamlPath: json['config_yaml_path'] ?? '',
      personaMdPath: json['persona_md_path'] ?? '',
      memoriesMdPath: json['memories_md_path'] ?? '',
      enabled: json['enabled'] ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'config_yaml_path': configYamlPath,
        'persona_md_path': personaMdPath,
        'memories_md_path': memoriesMdPath,
        'enabled': enabled,
      };
}

class MemoryConfig {
  bool shortTermEnabled;
  int shortTermMax;
  bool longTermEnabled;
  int longTermMax;
  int expireDays;
  int retrievalTopK;
  double retrievalMinScore;

  MemoryConfig({
    this.shortTermEnabled = true,
    this.shortTermMax = 20,
    this.longTermEnabled = true,
    this.longTermMax = 200,
    this.expireDays = 90,
    this.retrievalTopK = 5,
    this.retrievalMinScore = 0.2,
  });

  factory MemoryConfig.fromJson(Map<String, dynamic> json) {
    return MemoryConfig(
      shortTermEnabled: json['short_term_enabled'] ?? true,
      shortTermMax: json['short_term_max'] ?? 20,
      longTermEnabled: json['long_term_enabled'] ?? true,
      longTermMax: json['long_term_max'] ?? 200,
      expireDays: json['expire_days'] ?? 90,
      retrievalTopK: json['retrieval_top_k'] ?? 5,
      retrievalMinScore: (json['retrieval_min_score'] ?? 0.2).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'short_term_enabled': shortTermEnabled,
        'short_term_max': shortTermMax,
        'long_term_enabled': longTermEnabled,
        'long_term_max': longTermMax,
        'expire_days': expireDays,
        'retrieval_top_k': retrievalTopK,
        'retrieval_min_score': retrievalMinScore,
      };
}

class ToolsConfig {
  bool webSearch;
  String webSearchSource;

  ToolsConfig({
    this.webSearch = true,
    this.webSearchSource = 'searxng',
  });

  factory ToolsConfig.fromJson(Map<String, dynamic> json) {
    return ToolsConfig(
      webSearch: json['web_search'] ?? true,
      webSearchSource: json['web_search_source'] ?? 'searxng',
    );
  }

  Map<String, dynamic> toJson() => {
        'web_search': webSearch,
        'web_search_source': webSearchSource,
      };
}

class EmojiApiConfig {
  String apiId;
  String apiKey;
  String apiUrl;
  double probability;

  EmojiApiConfig({
    this.apiId = '',
    this.apiKey = '',
    this.apiUrl = '',
    this.probability = 0.5,
  });

  factory EmojiApiConfig.fromJson(Map<String, dynamic> json) {
    return EmojiApiConfig(
      apiId: json['api_id'] ?? '',
      apiKey: json['api_key'] ?? '',
      apiUrl: json['api_url'] ?? '',
      probability: (json['probability'] ?? 0.5).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'api_id': apiId,
        'api_key': apiKey,
        'api_url': apiUrl,
        'probability': probability,
      };
}

class ProactiveMessageConfig {
  bool enabled;
  int intervalMinutes;
  int maxIdleMinutes;
  double probability;

  ProactiveMessageConfig({
    this.enabled = true,
    this.intervalMinutes = 5,
    this.maxIdleMinutes = 10,
    this.probability = 0.8,
  });

  factory ProactiveMessageConfig.fromJson(Map<String, dynamic> json) {
    return ProactiveMessageConfig(
      enabled: json['enabled'] ?? true,
      intervalMinutes: json['interval_minutes'] ?? 5,
      maxIdleMinutes: json['max_idle_minutes'] ?? 10,
      probability: (json['probability'] ?? 0.8).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'interval_minutes': intervalMinutes,
        'max_idle_minutes': maxIdleMinutes,
        'probability': probability,
      };
}

class ImageHandlingConfig {
  bool sendToAi;
  String fallbackMode;
  String customMsg;

  ImageHandlingConfig({
    this.sendToAi = false,
    this.fallbackMode = 'auto',
    this.customMsg = '',
  });

  factory ImageHandlingConfig.fromJson(Map<String, dynamic> json) {
    return ImageHandlingConfig(
      sendToAi: json['send_to_ai'] ?? false,
      fallbackMode: json['fallback_mode'] ?? json['fallback_reply'] ?? 'auto',
      customMsg: json['custom_msg'] ?? json['unsupported_model_msg'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'send_to_ai': sendToAi,
        'fallback_mode': fallbackMode,
        'fallback_reply': fallbackMode,
        'custom_msg': customMsg,
        'unsupported_model_msg': customMsg,
      };
}

class FeaturesConfig {
  bool emoji;
  double emojiProbability;
  EmojiApiConfig emojiApi;
  int maxMessages;
  ProactiveMessageConfig proactiveMessage;
  bool fileReply;
  bool videoReply;
  bool voiceReply;
  bool typingIndicator;
  ImageHandlingConfig imageHandling;

  FeaturesConfig({
    this.emoji = true,
    this.emojiProbability = 0.5,
    EmojiApiConfig? emojiApi,
    this.maxMessages = 10,
    ProactiveMessageConfig? proactiveMessage,
    this.fileReply = true,
    this.videoReply = true,
    this.voiceReply = true,
    this.typingIndicator = true,
    ImageHandlingConfig? imageHandling,
  })  : emojiApi = emojiApi ?? EmojiApiConfig(),
        proactiveMessage = proactiveMessage ?? ProactiveMessageConfig(),
        imageHandling = imageHandling ?? ImageHandlingConfig();

  factory FeaturesConfig.fromJson(Map<String, dynamic> json) {
    return FeaturesConfig(
      emoji: json['emoji'] ?? true,
      emojiProbability: (json['emoji_probability'] ?? 0.5).toDouble(),
      emojiApi: EmojiApiConfig.fromJson(json['emoji_api'] ?? {}),
      maxMessages: json['max_messages'] ?? 10,
      proactiveMessage:
          ProactiveMessageConfig.fromJson(json['proactive_message'] ?? {}),
      fileReply: json['file_reply'] ?? true,
      videoReply: json['video_reply'] ?? true,
      voiceReply: json['voice_reply'] ?? true,
      typingIndicator: json['typing_indicator'] ?? true,
      imageHandling: ImageHandlingConfig.fromJson(json['image_handling'] ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'emoji': emoji,
        'emoji_probability': emojiProbability,
        'emoji_api': emojiApi.toJson(),
        'max_messages': maxMessages,
        'proactive_message': proactiveMessage.toJson(),
        'file_reply': fileReply,
        'video_reply': videoReply,
        'voice_reply': voiceReply,
        'typing_indicator': typingIndicator,
        'image_handling': imageHandling.toJson(),
      };
}

class SystemConfig {
  double temperature;
  int maxTokens;
  int timeout;

  SystemConfig({
    this.temperature = 0.7,
    this.maxTokens = 2000,
    this.timeout = 120,
  });

  factory SystemConfig.fromJson(Map<String, dynamic> json) {
    return SystemConfig(
      temperature: (json['temperature'] ?? 0.7).toDouble(),
      maxTokens: json['max_tokens'] ?? 2000,
      timeout: json['timeout'] ?? 120,
    );
  }

  Map<String, dynamic> toJson() => {
        'temperature': temperature,
        'max_tokens': maxTokens,
        'timeout': timeout,
      };
}
