import 'package:flutter/material.dart';
import '../chat_store.dart';
import 'ai_service.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, required this.store});
  final ChatStore store;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final Map<AiProviderType, TextEditingController> _keyControllers = {};
  final Map<AiProviderType, TextEditingController> _modelControllers = {};
  final Map<AiProviderType, TextEditingController> _urlControllers = {};

  @override
  void initState() {
    super.initState();
    for (final entry in AiService.instance.providers.entries) {
      _keyControllers[entry.key] = TextEditingController(text: entry.value.apiKey);
      _modelControllers[entry.key] = TextEditingController(text: entry.value.defaultModel);
      _urlControllers[entry.key] = TextEditingController(text: entry.value.baseUrl);
    }
  }

  @override
  void dispose() {
    for (final c in _keyControllers.values) {
      c.dispose();
    }
    for (final c in _modelControllers.values) {
      c.dispose();
    }
    for (final c in _urlControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _saveSettings() async {
    for (final entry in AiService.instance.providers.entries) {
      entry.value.apiKey = _keyControllers[entry.key]!.text.trim();
      entry.value.baseUrl = _urlControllers[entry.key]!.text.trim();
    }
    await AiService.instance.save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AI provider configurations saved successfully!')),
      );
    }
  }

  void _addAiChat(AiProviderType type, String name, int color) async {
    final existing = widget.store.conversations.any((c) => c.isAi && c.aiProvider == type.name);
    if (existing) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name is already in your chat list!')),
      );
      return;
    }

    await widget.store.createAiChat(
      name: name,
      provider: type.name,
      color: color,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $name to your WhatsApp chats!')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Providers (Meta AI / LLMs)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Save Settings',
            onPressed: _saveSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            elevation: 0,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, size: 36, color: Color(0xFF245CDB)),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WhatsApp AI Assistants',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Add ChatGPT, Claude, Gemini, or DeepSeek directly into your chats. Conversations run locally and securely with your own API keys.',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Configure Providers',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildProviderCard(
            type: AiProviderType.openai,
            title: 'ChatGPT (OpenAI)',
            icon: Icons.smart_toy_outlined,
            color: const Color(0xFF10A37F),
            keyHint: 'sk-proj-...',
          ),
          _buildProviderCard(
            type: AiProviderType.anthropic,
            title: 'Claude (Anthropic)',
            icon: Icons.psychology_outlined,
            color: const Color(0xFFD97706),
            keyHint: 'sk-ant-...',
          ),
          _buildProviderCard(
            type: AiProviderType.gemini,
            title: 'Google Gemini',
            icon: Icons.diamond_outlined,
            color: const Color(0xFF3B82F6),
            keyHint: 'AIzaSy...',
          ),
          _buildProviderCard(
            type: AiProviderType.deepseek,
            title: 'DeepSeek',
            icon: Icons.blur_on,
            color: const Color(0xFF4F46E5),
            keyHint: 'sk-...',
          ),
          _buildProviderCard(
            type: AiProviderType.custom,
            title: 'Custom (Ollama / Local / OpenRouter)',
            icon: Icons.terminal_outlined,
            color: const Color(0xFF64748B),
            keyHint: 'Optional API Key',
            showUrlField: true,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saveSettings,
            icon: const Icon(Icons.save),
            label: const Text('Save API Keys & Settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderCard({
    required AiProviderType type,
    required String title,
    required IconData icon,
    required Color color,
    required String keyHint,
    bool showUrlField = false,
  }) {
    final config = AiService.instance.providers[type]!;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('Model: ${config.defaultModel}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _addAiChat(type, title, color.toARGB32()),
                  icon: const Icon(Icons.add_comment_outlined, size: 16),
                  label: const Text('Add Chat'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _keyControllers[type],
              obscureText: type != AiProviderType.custom,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: keyHint,
                prefixIcon: const Icon(Icons.key, size: 20),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
            if (showUrlField) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _urlControllers[type],
                decoration: const InputDecoration(
                  labelText: 'API Endpoint URL',
                  hintText: 'http://localhost:11434/v1/chat/completions',
                  prefixIcon: Icon(Icons.link, size: 20),
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
