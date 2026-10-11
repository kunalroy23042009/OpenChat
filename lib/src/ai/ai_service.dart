import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../chat_store.dart';

enum AiProviderType {
  openai,
  anthropic,
  gemini,
  deepseek,
  custom,
}

class AiProviderConfig {
  AiProviderConfig({
    required this.type,
    required this.name,
    required this.defaultModel,
    this.apiKey = '',
    this.baseUrl = '',
    this.systemPrompt = 'You are a helpful, secure AI assistant inside OpenChat.',
  });

  final AiProviderType type;
  final String name;
  final String defaultModel;
  String apiKey;
  String baseUrl;
  String systemPrompt;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'name': name,
        'defaultModel': defaultModel,
        'apiKey': apiKey,
        'baseUrl': baseUrl,
        'systemPrompt': systemPrompt,
      };

  factory AiProviderConfig.fromJson(Map<String, dynamic> json) =>
      AiProviderConfig(
        type: AiProviderType.values.byName(json['type'] as String),
        name: json['name'] as String,
        defaultModel: json['defaultModel'] as String,
        apiKey: json['apiKey'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
        systemPrompt: json['systemPrompt'] as String? ??
            'You are a helpful, secure AI assistant inside OpenChat.',
      );
}

class AiService {
  AiService._();
  static final AiService instance = AiService._();

  SharedPreferences? _prefs;
  static const String _storageKey = 'openchat.ai_providers.v1';

  final Map<AiProviderType, AiProviderConfig> providers = {
    AiProviderType.openai: AiProviderConfig(
      type: AiProviderType.openai,
      name: 'ChatGPT (OpenAI)',
      defaultModel: 'gpt-4o-mini',
      baseUrl: 'https://api.openai.com/v1/chat/completions',
    ),
    AiProviderType.anthropic: AiProviderConfig(
      type: AiProviderType.anthropic,
      name: 'Claude (Anthropic)',
      defaultModel: 'claude-3-5-haiku-20241022',
      baseUrl: 'https://api.anthropic.com/v1/messages',
    ),
    AiProviderType.gemini: AiProviderConfig(
      type: AiProviderType.gemini,
      name: 'Google Gemini',
      defaultModel: 'gemini-1.5-flash',
      baseUrl:
          'https://generativelanguage.googleapis.com/v1beta/models',
    ),
    AiProviderType.deepseek: AiProviderConfig(
      type: AiProviderType.deepseek,
      name: 'DeepSeek',
      defaultModel: 'deepseek-chat',
      baseUrl: 'https://api.deepseek.com/chat/completions',
    ),
    AiProviderType.custom: AiProviderConfig(
      type: AiProviderType.custom,
      name: 'Custom (Ollama / Local / OpenRouter)',
      defaultModel: 'default',
      baseUrl: 'http://localhost:11434/v1/chat/completions',
    ),
  };

  Future<void> init(SharedPreferences prefs) async {
    _prefs = prefs;
    final saved = prefs.getString(_storageKey);
    if (saved != null) {
      try {
        final list = (jsonDecode(saved) as List)
            .map((e) => AiProviderConfig.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        for (final p in list) {
          providers[p.type] = p;
        }
      } catch (_) {}
    }
  }

  Future<void> save() async {
    if (_prefs == null) return;
    final data = jsonEncode(providers.values.map((p) => p.toJson()).toList());
    await _prefs!.setString(_storageKey, data);
  }

  Future<String> generateReply({
    required AiProviderType providerType,
    required String userPrompt,
    required List<ChatMessage> history,
  }) async {
    final config = providers[providerType];
    if (config == null) {
      return 'AI Provider configuration not found.';
    }

    // If no API key is provided, provide an intelligent demo reply
    if (config.apiKey.trim().isEmpty && providerType != AiProviderType.custom) {
      return _generateDemoReply(config.name, userPrompt);
    }

    try {
      switch (providerType) {
        case AiProviderType.openai:
        case AiProviderType.deepseek:
        case AiProviderType.custom:
          return await _callOpenAiCompatible(config, userPrompt, history);
        case AiProviderType.anthropic:
          return await _callAnthropic(config, userPrompt, history);
        case AiProviderType.gemini:
          return await _callGemini(config, userPrompt, history);
      }
    } catch (e) {
      return 'Could not connect to ${config.name}: $e\n\n(Tip: Check your API key and network connection in Settings → AI Assistants.)';
    }
  }

  Future<String> _callOpenAiCompatible(
    AiProviderConfig config,
    String userPrompt,
    List<ChatMessage> history,
  ) async {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': config.systemPrompt},
    ];

    for (final m in history.reversed.take(6).toList().reversed) {
      messages.add({
        'role': m.mine ? 'user' : 'assistant',
        'content': m.text,
      });
    }

    messages.add({'role': 'user', 'content': userPrompt});

    final response = await http.post(
      Uri.parse(config.baseUrl),
      headers: {
        'Content-Type': 'application/json',
        if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey.trim()}',
      },
      body: jsonEncode({
        'model': config.defaultModel,
        'messages': messages,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Server returned ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List;
    if (choices.isNotEmpty) {
      final msg = choices[0]['message'] as Map<String, dynamic>;
      return (msg['content'] as String).trim();
    }
    return 'No response received from AI model.';
  }

  Future<String> _callAnthropic(
    AiProviderConfig config,
    String userPrompt,
    List<ChatMessage> history,
  ) async {
    final messages = <Map<String, String>>[];

    for (final m in history.reversed.take(6).toList().reversed) {
      messages.add({
        'role': m.mine ? 'user' : 'assistant',
        'content': m.text,
      });
    }
    messages.add({'role': 'user', 'content': userPrompt});

    final response = await http.post(
      Uri.parse(config.baseUrl),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': config.apiKey.trim(),
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': config.defaultModel,
        'max_tokens': 1024,
        'system': config.systemPrompt,
        'messages': messages,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Server returned ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content = data['content'] as List;
    if (content.isNotEmpty) {
      return (content[0]['text'] as String).trim();
    }
    return 'No response received from Claude.';
  }

  Future<String> _callGemini(
    AiProviderConfig config,
    String userPrompt,
    List<ChatMessage> history,
  ) async {
    final url =
        '${config.baseUrl}/${config.defaultModel}:generateContent?key=${config.apiKey.trim()}';

    final contents = <Map<String, dynamic>>[];
    for (final m in history.reversed.take(6).toList().reversed) {
      contents.add({
        'role': m.mine ? 'user' : 'model',
        'parts': [
          {'text': m.text}
        ],
      });
    }
    contents.add({
      'role': 'user',
      'parts': [
        {'text': userPrompt}
      ],
    });

    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'contents': contents}),
    );

    if (response.statusCode != 200) {
      throw Exception('Server returned ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    if (candidates != null && candidates.isNotEmpty) {
      final parts = candidates[0]['content']['parts'] as List;
      if (parts.isNotEmpty) {
        return (parts[0]['text'] as String).trim();
      }
    }
    return 'No response received from Gemini.';
  }

  String _generateDemoReply(String providerName, String prompt) {
    final lower = prompt.toLowerCase();
    if (lower.contains('hello') || lower.contains('hi')) {
      return 'Hello! I am $providerName running in OpenChat. You can ask me questions, draft messages, or add your API key in Settings → AI Assistants for live models!';
    }
    if (lower.contains('what is') || lower.contains('how')) {
      return 'That is a great question! In live mode, $providerName searches and reasons through extensive context. Add your API key in Settings → AI Assistants to unlock full LLM capabilities.';
    }
    return '[$providerName Response]\nReceived: "$prompt"\n\nTo connect live cloud intelligence from ChatGPT, Claude, or Gemini, configure your API key in Settings → AI Assistants.';
  }
}
