import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PrivacySettingsPage extends StatefulWidget {
  const PrivacySettingsPage({
    super.key,
    required this.preferences,
    this.client,
  });

  final SharedPreferences preferences;
  final SupabaseClient? client;

  @override
  State<PrivacySettingsPage> createState() => _PrivacySettingsPageState();
}

class _PrivacySettingsPageState extends State<PrivacySettingsPage> {
  bool readReceipts = true;
  bool focusMode = false;
  bool appLock = false;
  String lastSeen = 'contacts';
  String photoPrivacy = 'contacts';
  String statusPrivacy = 'contacts';
  int disappearingSeconds = 604800;
  String focusMessage = 'I am focusing right now and will reply later.';
  List<Map<String, dynamic>> sessions = const [];
  bool loadingSessions = false;

  static const _prefix = 'openchat.privacy.';

  @override
  void initState() {
    super.initState();
    readReceipts = widget.preferences.getBool('${_prefix}readReceipts') ?? true;
    focusMode = widget.preferences.getBool('${_prefix}focusMode') ?? false;
    appLock = widget.preferences.getBool('${_prefix}appLock') ?? false;
    lastSeen = widget.preferences.getString('${_prefix}lastSeen') ?? 'contacts';
    photoPrivacy =
        widget.preferences.getString('${_prefix}photoPrivacy') ?? 'contacts';
    statusPrivacy =
        widget.preferences.getString('${_prefix}statusPrivacy') ?? 'contacts';
    disappearingSeconds =
        widget.preferences.getInt('${_prefix}disappearing') ?? 604800;
    focusMessage =
        widget.preferences.getString('${_prefix}focusMessage') ?? focusMessage;
    _loadSessions();
  }

  Future<void> _save() async {
    await Future.wait([
      widget.preferences.setBool('${_prefix}readReceipts', readReceipts),
      widget.preferences.setBool('${_prefix}focusMode', focusMode),
      widget.preferences.setBool('${_prefix}appLock', appLock),
      widget.preferences.setString('${_prefix}lastSeen', lastSeen),
      widget.preferences.setString('${_prefix}photoPrivacy', photoPrivacy),
      widget.preferences.setString('${_prefix}statusPrivacy', statusPrivacy),
      widget.preferences.setInt('${_prefix}disappearing', disappearingSeconds),
      widget.preferences.setString('${_prefix}focusMessage', focusMessage),
    ]);
    final client = widget.client;
    if (client?.auth.currentUser != null) {
      try {
        await client!.rpc(
          'upsert_preferences',
          params: {
            'p_values': {
              'read_receipts': readReceipts,
              'last_seen_privacy': lastSeen,
              'profile_photo_privacy': photoPrivacy,
              'status_privacy': statusPrivacy,
              'default_disappearing_seconds': disappearingSeconds,
              'focus_mode': focusMode,
              'focus_message': focusMessage,
            },
          },
        );
      } catch (_) {
        // Local privacy choices remain effective if the backend is offline.
      }
    }
  }

  String get _platform {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => 'web',
    };
  }

  Future<void> _registerCurrentDevice() async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    var token = widget.preferences.getString('${_prefix}deviceToken');
    token ??=
        '${client!.auth.currentUser!.id}-${DateTime.now().microsecondsSinceEpoch}';
    await widget.preferences.setString('${_prefix}deviceToken', token);
    await client!.rpc(
      'register_device_session',
      params: {
        'p_label': kIsWeb
            ? 'Web browser'
            : '${defaultTargetPlatform.name} device',
        'p_platform': _platform,
        'p_token_hash': token,
        'p_os_version': null,
        'p_is_primary': !kIsWeb,
      },
    );
    await _loadSessions();
  }

  Future<void> _loadSessions() async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    setState(() => loadingSessions = true);
    try {
      final rows =
          await client!
                  .from('devices')
                  .select()
                  .order('last_active_at', ascending: false)
              as List<dynamic>;
      if (mounted) {
        setState(() => sessions = rows.cast<Map<String, dynamic>>());
      }
    } catch (_) {
      // Migration may not be deployed yet; keep the settings page usable.
    } finally {
      if (mounted) setState(() => loadingSessions = false);
    }
  }

  Future<void> _logoutSession(String id) async {
    await widget.client?.from('devices').delete().eq('id', id);
    await _loadSessions();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy and sessions')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          value: readReceipts,
          title: const Text('Read receipts'),
          subtitle: const Text('Show blue checks and status viewers'),
          onChanged: (value) {
            setState(() => readReceipts = value);
            _save();
          },
        ),
        _privacyChoice(
          'Last seen and online',
          lastSeen,
          (value) => lastSeen = value,
        ),
        _privacyChoice(
          'Profile photo',
          photoPrivacy,
          (value) => photoPrivacy = value,
        ),
        _privacyChoice(
          'Status audience',
          statusPrivacy,
          (value) => statusPrivacy = value,
          status: true,
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Default disappearing timer'),
          subtitle: Text(switch (disappearingSeconds) {
            86400 => '24 hours',
            7776000 => '90 days',
            _ => '7 days',
          }),
          onTap: _chooseTimer,
        ),
        SwitchListTile(
          value: focusMode,
          title: const Text('Focus mode'),
          subtitle: Text(focusMessage),
          onChanged: (value) {
            setState(() => focusMode = value);
            _save();
          },
        ),
        SwitchListTile(
          value: appLock,
          title: const Text('App lock'),
          subtitle: const Text(
            'Require the device lock when supported by the platform',
          ),
          onChanged: (value) {
            setState(() => appLock = value);
            _save();
          },
        ),
        const Divider(height: 32),
        Row(
          children: [
            Text(
              'Linked devices',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            TextButton(
              onPressed: widget.client?.auth.currentUser == null
                  ? null
                  : _registerCurrentDevice,
              child: const Text('Link this device'),
            ),
          ],
        ),
        if (loadingSessions) const LinearProgressIndicator(),
        if (!loadingSessions && sessions.isEmpty)
          const ListTile(
            leading: Icon(Icons.devices_other),
            title: Text('No linked cloud sessions'),
            subtitle: Text('Sign in and link this device to manage it here.'),
          ),
        ...sessions.map(
          (session) => ListTile(
            leading: Icon(
              session['platform'] == 'web'
                  ? Icons.language
                  : Icons.phone_android,
            ),
            title: Text(session['label'] as String? ?? 'Device'),
            subtitle: Text(
              '${session['platform']} • last active ${session['last_active_at'] ?? 'unknown'}',
            ),
            trailing: IconButton(
              tooltip: 'Log out device',
              icon: const Icon(Icons.logout),
              onPressed: () => _logoutSession(session['id'] as String),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _privacyChoice(
    String title,
    String value,
    ValueChanged<String> assign, {
    bool status = false,
  }) => ListTile(
    title: Text(title),
    subtitle: Text(value),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      final options = status
          ? const ['contacts', 'except', 'only']
          : const ['everyone', 'contacts', 'nobody'];
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(title),
          children: options
              .map(
                (option) => ListTile(
                  leading: Icon(
                    option == value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(option),
                  onTap: () => Navigator.pop(context, option),
                ),
              )
              .toList(),
        ),
      );
      if (selected != null) {
        setState(() => assign(selected));
        _save();
      }
    },
  );

  Future<void> _chooseTimer() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Disappearing messages'),
        children:
            const {86400: '24 hours', 604800: '7 days', 7776000: '90 days'}
                .entries
                .map(
                  (entry) => ListTile(
                    leading: Icon(
                      entry.key == disappearingSeconds
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Text(entry.value),
                    onTap: () => Navigator.pop(context, entry.key),
                  ),
                )
                .toList(),
      ),
    );
    if (selected != null) {
      setState(() => disappearingSeconds = selected);
      _save();
    }
  }
}
