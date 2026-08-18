import 'dart:convert';

enum AiProviderKind { openaiCompatible, ollama }

AiProviderKind aiProviderKindFromJson(Object? value) {
  return switch (value) {
    'ollama' => AiProviderKind.ollama,
    'openai_compatible' => AiProviderKind.openaiCompatible,
    _ => throw const FormatException('Unsupported AI provider type'),
  };
}

String aiProviderKindToJson(AiProviderKind value) => switch (value) {
  AiProviderKind.openaiCompatible => 'openai_compatible',
  AiProviderKind.ollama => 'ollama',
};

class AiProviderConfig {
  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.model,
    this.enabled = true,
    this.requestParameters = const {},
    this.keyConfigured = false,
  });

  factory AiProviderConfig.fromJson(Map<String, dynamic> json) {
    final id = _required(json['id'], 'id');
    final name = _required(json['name'], 'name');
    final baseUrl = _required(json['base_url'], 'base_url');
    final model = _required(json['model'], 'model');
    final rawParameters = json['request_parameters'];
    if (rawParameters != null && rawParameters is! Map) {
      throw const FormatException('request_parameters must be an object');
    }
    return AiProviderConfig(
      id: id,
      name: name,
      kind: aiProviderKindFromJson(json['kind']),
      baseUrl: baseUrl,
      model: model,
      enabled: json['enabled'] as bool? ?? true,
      requestParameters: rawParameters == null
          ? const {}
          : Map<String, dynamic>.from(rawParameters as Map),
      keyConfigured: json['key_configured'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final AiProviderKind kind;
  final String baseUrl;
  final String model;
  final bool enabled;
  final Map<String, dynamic> requestParameters;

  static const int defaultRequestTimeoutSeconds = 45;
  static const int defaultRetryCount = 2;

  int get requestTimeoutSeconds => _integerParameter(
    'request_timeout_seconds',
    defaultValue: defaultRequestTimeoutSeconds,
    minimum: 5,
    maximum: 300,
  );

  int get retryCount => _integerParameter(
    'retry_count',
    defaultValue: defaultRetryCount,
    minimum: 0,
    maximum: 5,
  );

  double get temperature {
    final value = requestParameters['temperature'];
    return value is num ? value.toDouble().clamp(0, 2).toDouble() : 0;
  }

  int? get maxTokens {
    final value = requestParameters['max_tokens'];
    if (value is! num) return null;
    return value.toInt().clamp(1, 1000000).toInt();
  }

  String? get proxyUrl {
    final value = requestParameters['proxy_url'];
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }

  // This is derived from secure storage and is deliberately omitted from JSON.
  final bool keyConfigured;

  Map<String, dynamic> get nonSensitiveRequestParameters => {
    for (final entry in requestParameters.entries)
      if (!_sensitiveParameter(entry.key)) entry.key: entry.value,
  };

  Map<String, dynamic> get payloadRequestParameters => {
    for (final entry in nonSensitiveRequestParameters.entries)
      if (!const {
        'request_timeout_seconds',
        'retry_count',
        'proxy_url',
        'temperature',
        'max_tokens',
        'model',
        'messages',
        'stream',
        'format',
        'response_format',
      }.contains(entry.key))
        entry.key: entry.value,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': aiProviderKindToJson(kind),
    'base_url': baseUrl,
    'model': model,
    'enabled': enabled,
    'request_parameters': nonSensitiveRequestParameters,
  };

  String toStorageJson() => jsonEncode(toJson());

  AiProviderConfig copyWith({
    String? id,
    String? name,
    AiProviderKind? kind,
    String? baseUrl,
    String? model,
    bool? enabled,
    Map<String, dynamic>? requestParameters,
    bool? keyConfigured,
  }) => AiProviderConfig(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    enabled: enabled ?? this.enabled,
    requestParameters: requestParameters ?? this.requestParameters,
    keyConfigured: keyConfigured ?? this.keyConfigured,
  );

  static String _required(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field must be a non-empty string');
    }
    return value.trim();
  }

  static bool _sensitiveParameter(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[_\-.]'), '');
    return const {
      'apikey',
      'authorization',
      'token',
      'accesstoken',
      'refreshtoken',
      'secret',
      'clientsecret',
    }.contains(normalized);
  }

  int _integerParameter(
    String key, {
    required int defaultValue,
    required int minimum,
    required int maximum,
  }) {
    final value = requestParameters[key];
    if (value is! num) return defaultValue;
    return value.toInt().clamp(minimum, maximum).toInt();
  }
}

class AiProviderImport {
  const AiProviderImport({
    required this.config,
    this.apiKey,
    this.clearApiKey = false,
  });

  factory AiProviderImport.fromJson(Map<String, dynamic> json) {
    final normalized = Map<String, dynamic>.from(json);
    normalized.putIfAbsent(
      'id',
      () => 'ai_${DateTime.now().microsecondsSinceEpoch}',
    );
    final config = AiProviderConfig.fromJson(normalized);
    final rawKey = json['api_key'];
    if (rawKey != null && rawKey is! String) {
      throw const FormatException('api_key must be a string');
    }
    return AiProviderImport(
      config: config,
      apiKey: (rawKey as String?)?.trim(),
    );
  }

  final AiProviderConfig config;
  final String? apiKey;
  final bool clearApiKey;
}
