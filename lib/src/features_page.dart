import 'package:flutter/material.dart';

import 'chat_preferences.dart';

class FeatureHubPage extends StatefulWidget {
  const FeatureHubPage({super.key, required this.preferences});

  final ChatPreferences preferences;

  @override
  State<FeatureHubPage> createState() => _FeatureHubPageState();
}

class _FeatureHubPageState extends State<FeatureHubPage> {
  late bool _hdMedia;
  late bool _lowData;

  @override
  void initState() {
    super.initState();
    _hdMedia = widget.preferences.hdMedia;
    _lowData = widget.preferences.lowDataMode;
  }

  Future<void> _setHd(bool value) async {
    await widget.preferences.setHdMedia(value);
    if (mounted) setState(() => _hdMedia = value);
  }

  Future<void> _setLowData(bool value) async {
    await widget.preferences.setLowDataMode(value);
    if (mounted) setState(() => _lowData = value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OpenChat features')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _FeatureIntro(),
          const SizedBox(height: 20),
          const _FeatureHeading('Chats & sharing'),
          _FeatureCard(
            icon: Icons.wallpaper_outlined,
            title: 'Chat wallpapers & themes',
            detail: 'Choose a personal wallpaper from any chat menu.',
            ready: true,
          ),
          _FeatureCard(
            icon: Icons.reply_outlined,
            title: 'Replies, reactions and message tools',
            detail:
                'Quote, react, edit, star, pin, forward and delete messages.',
            ready: true,
          ),
          _FeatureCard(
            icon: Icons.folder_shared_outlined,
            title: 'Documents and large files',
            detail: 'Send encrypted documents up to 200 MB, subject to storage limits.',
            ready: true,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.hd_outlined),
            title: const Text('HD media sharing'),
            subtitle: const Text(
              'Keep higher image quality when sharing photos.',
            ),
            value: _hdMedia,
            onChanged: _setHd,
          ),
          const SizedBox(height: 12),
          const _FeatureHeading('Calls'),
          _FeatureCard(
            icon: Icons.video_call_outlined,
            title: 'Voice and HD video calls',
            detail:
                'Encrypted 1:1 calls with mute, speaker and camera controls.',
            ready: true,
          ),
          _FeatureCard(
            icon: Icons.history_outlined,
            title: 'Call history and missed calls',
            detail: 'Review calls and redial from the Calls tab.',
            ready: true,
          ),
          _FeatureCard(
            icon: Icons.screen_share_outlined,
            title: 'Screen sharing and group calls',
            detail: 'Planned for a later calling milestone.',
            ready: false,
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.data_saver_on_outlined),
            title: const Text('Use less data for calls'),
            subtitle: const Text(
              'Prefer a lighter media profile on mobile data.',
            ),
            value: _lowData,
            onChanged: _setLowData,
          ),
          const SizedBox(height: 12),
          const _FeatureHeading('Status & privacy'),
          _FeatureCard(
            icon: Icons.circle_outlined,
            title: 'Status updates',
            detail: 'Post text, photo and video updates that expire after 24 hours.',
            ready: true,
          ),
          _FeatureCard(
            icon: Icons.lock_outline,
            title: 'Chat lock and encrypted messaging',
            detail: 'Protect selected chats with a PIN and keep messages end-to-end encrypted.',
            ready: true,
          ),
          _FeatureCard(
            icon: Icons.tune_outlined,
            title: 'Custom chat lists',
            detail: 'Favorites and archive are available now; named lists are next.',
            ready: false,
          ),
        ],
      ),
    );
  }
}

class _FeatureIntro extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: const Padding(
        padding: EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome_outlined),
            SizedBox(width: 14),
            Expanded(
              child: Text(
                'Your OpenChat toolkit\nExplore what is ready today and tune the experience for this device.',
                style: TextStyle(fontWeight: FontWeight.w600, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureHeading extends StatelessWidget {
  const _FeatureHeading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
      ),
    ),
  );
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.detail,
    required this.ready,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool ready;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(
      backgroundColor: ready
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(icon),
    ),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(detail),
    trailing: Chip(
      label: Text(ready ? 'Ready' : 'Next'),
      visualDensity: VisualDensity.compact,
      backgroundColor: ready
          ? const Color(0xFFD9FBEA)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
    ),
  );
}
