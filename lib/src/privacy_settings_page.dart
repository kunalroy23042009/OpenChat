import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_lock.dart';
import 'contacts_repository.dart';
import 'privacy_audience_dialog.dart';
import 'two_factor_screen.dart';

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
  String aboutPrivacy = 'contacts';
  String statusPrivacy = 'contacts';
  int disappearingSeconds = 0;
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
    aboutPrivacy =
        widget.preferences.getString('${_prefix}aboutPrivacy') ?? 'contacts';
    statusPrivacy =
        widget.preferences.getString('${_prefix}statusPrivacy') ?? 'contacts';
    disappearingSeconds =
        widget.preferences.getInt('${_prefix}disappearing') ?? 0;
    focusMessage =
        widget.preferences.getString('${_prefix}focusMessage') ?? focusMessage;
    _loadSessions();
    _loadCloudPrivacy();
  }

  Future<void> _save() async {
    await Future.wait([
      widget.preferences.setBool('${_prefix}readReceipts', readReceipts),
      widget.preferences.setBool('${_prefix}focusMode', focusMode),
      widget.preferences.setBool('${_prefix}appLock', appLock),
      widget.preferences.setString('${_prefix}lastSeen', lastSeen),
      widget.preferences.setString('${_prefix}photoPrivacy', photoPrivacy),
      widget.preferences.setString('${_prefix}aboutPrivacy', aboutPrivacy),
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
              'about_privacy': aboutPrivacy,
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

  Future<void> _loadCloudPrivacy() async {
    final client = widget.client;
    final userId = client?.auth.currentUser?.id;
    if (client == null || userId == null) return;
    try {
      final row = await client
          .from('user_preferences')
          .select(
            'last_seen_privacy, profile_photo_privacy, about_privacy, status_privacy',
          )
          .eq('user_id', userId)
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        lastSeen = row['last_seen_privacy'] as String? ?? lastSeen;
        photoPrivacy = row['profile_photo_privacy'] as String? ?? photoPrivacy;
        aboutPrivacy = row['about_privacy'] as String? ?? aboutPrivacy;
        statusPrivacy = row['status_privacy'] as String? ?? statusPrivacy;
      });
    } catch (_) {
      // The local settings remain usable offline and on older backends.
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
          field: 'last_seen',
        ),
        _privacyChoice(
          'Profile photo',
          photoPrivacy,
          (value) => photoPrivacy = value,
          field: 'profile_photo',
        ),
        _privacyChoice(
          'About',
          aboutPrivacy,
          (value) => aboutPrivacy = value,
          field: 'about',
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
            0 => 'Off (messages are kept forever)',
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
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('Secret code for locked chats'),
          subtitle: const Text(
            'Hide the Locked folder. Type the code in search to reveal it.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editSecretCode,
        ),
        if (widget.client?.auth.currentUser != null)
          ListTile(
            leading: const Icon(Icons.security_outlined),
            title: const Text('Two-factor authentication'),
            subtitle: const Text(
              'Add a 6-digit authenticator app code for account recovery.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => TwoFactorScreen(client: widget.client!),
              ),
            ),
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
    String? field,
  }) => ListTile(
    title: Text(title),
    subtitle: Text(_privacyLabel(value)),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      final options = status
          ? const ['contacts', 'except', 'only']
          : const ['everyone', 'contacts', 'except', 'only', 'nobody'];
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
                  title: Text(_privacyLabel(option)),
                  onTap: () => Navigator.pop(context, option),
                ),
              )
              .toList(),
        ),
      );
      if (selected != null) {
        if (field != null && (selected == 'except' || selected == 'only')) {
          final configured = await _chooseAudience(field, title, selected);
          if (!configured) return;
        }
        setState(() => assign(selected));
        _save();
      }
    },
  );

  String _privacyLabel(String value) => switch (value) {
    'everyone' => 'Everyone',
    'contacts' => 'My contacts',
    'except' => 'My contacts except...',
    'only' => 'Only share with...',
    'nobody' => 'Nobody',
    _ => value,
  };

  Future<bool> _chooseAudience(String field, String title, String mode) async {
    final client = widget.client;
    if (client?.auth.currentUser == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to choose specific contacts.')),
        );
      }
      return false;
    }
    try {
      final contacts = (await SupabaseContactsRepository(
        client!,
      ).contacts()).where((contact) => contact.status == 'accepted').toList();
      final saved = await client.rpc(
        'list_profile_visibility_exceptions',
        params: {'p_field': field},
      ) as List;
      final selected = saved.map((id) => id.toString()).toSet();
      if (!mounted) return false;
      final result = await showDialog<Set<String>>(
        context: context,
        builder: (context) => AudienceDialog(
          title: mode == 'except'
              ? '$title: contacts except'
              : '$title: only share with',
          contacts: contacts,
          selected: selected,
        ),
      );
      if (result == null) return false;
      await client.rpc(
        'replace_profile_visibility_exceptions',
        params: {'p_field': field, 'p_subject_ids': result.toList()},
      );
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update the selected contacts.'),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _editSecretCode() async {
    final current = await ChatLock.secretCode();
    if (!mounted) return;
    final controller = TextEditingController(text: current ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Secret code'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(
            hintText: 'e.g. mango42 (empty = off)',
            border: OutlineInputBorder(),
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await ChatLock.setSecretCode(controller.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              controller.text.trim().isEmpty
                  ? 'Secret code off. Locked folder is visible again.'
                  : 'Secret code saved. Locked folder is now hidden.',
            ),
          ),
        );
      }
    }
    controller.dispose();
  }

  Future<void> _chooseTimer() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Disappearing messages'),
        children:
            const {
              0: 'Off (default)',
              86400: '24 hours',
              604800: '7 days',
              7776000: '90 days',
            }
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
