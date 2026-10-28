import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_lock.dart';
import 'chat_preferences.dart';
import 'chat_store.dart';
import 'media/encrypted_media_browser.dart';
import 'auth/password_auth.dart';
import 'auth/password_field.dart';
import 'auth/password_page.dart';
import 'auth/phone_auth.dart';
import 'auth/phone_auth_page.dart';
import 'contacts_page.dart';
import 'contacts_repository.dart';
import 'google_sign_in.dart';
import 'local_profile.dart';
import 'profile_page.dart';
import 'push/push_service.dart';
import 'recovery_page.dart';
import 'theme/app_theme.dart';
import 'backup/backup_page.dart';
import 'privacy_settings_page.dart';
import 'security/app_lock.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.profile,
    required this.push,
    this.client,
    this.startupError,
    this.theme,
  });
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  final SupabaseClient? client;
  final String? startupError;
  final AppThemeController? theme;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String? feedback;
  StreamSubscription<AuthState>? authSubscription;
  late AppThemeController theme;
  late bool hdMedia;
  late bool lowDataMode;
  @override
  void initState() {
    super.initState();
    theme = widget.theme ?? AppThemeController(widget.store.preferences);
    final chatPrefs = ChatPreferences(widget.store.preferences);
    hdMedia = chatPrefs.hdMedia;
    lowDataMode = chatPrefs.lowDataMode;
    authSubscription = widget.client?.auth.onAuthStateChange.listen(
      (_) {
        if (mounted) setState(() {});
        final client = widget.client;
        if (client?.auth.currentUser != null) {
          widget.push.syncAccount(client!);
        }
      },
      onError: (Object _) {
        if (mounted) {
          setState(
            () => feedback = 'Your session could not refresh. Check your connection or sign in again.',
          );
        }
      },
    );
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> authenticate(bool register) async {
    if (busy) return;
    final validation = credentialsValidation(
      email.text,
      password.text,
      register: register,
    );
    if (validation != null) {
      setState(() => feedback = validation);
      return;
    }
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      final signedIn = await PasswordAuth(widget.client!)
          .authenticate(email.text, password.text, register: register);
      if (!mounted) return;
      feedback = signedIn
          ? 'Signed in. Open People & profile to set your username and invite contacts.'
          : 'Check your email to confirm your account, then sign in.';
      if (signedIn) password.clear();
    } on AuthException catch (e) {
      feedback = passwordAuthError(e);
    } catch (_) {
      feedback = 'Could not connect. Check your connection and try again.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  static Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 4),
    child: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF66748A)),
    ),
  );

  Future<void> _setHdMedia(bool value) async {
    await ChatPreferences(widget.store.preferences).setHdMedia(value);
    if (mounted) setState(() => hdMedia = value);
  }

  Future<void> _setLowData(bool value) async {
    await ChatPreferences(widget.store.preferences).setLowDataMode(value);
    if (mounted) setState(() => lowDataMode = value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            ListenableBuilder(
              listenable: widget.profile,
              builder: (context, _) {
                final name = widget.profile.name.isEmpty
                    ? 'Add your name'
                    : widget.profile.name;
                final avatar = widget.profile.avatarFile;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 30,
                    backgroundColor: const Color(0xFFDDE5FF),
                    backgroundImage: avatar != null
                        ? FileImage(avatar)
                        : null,
                    child: avatar == null
                        ? Text(
                            name.isEmpty
                                ? '?'
                                : name[0].toUpperCase(),
                            style: const TextStyle(
                              fontSize: 28,
                              color: Color(0xFF245CDB),
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : null,
                  ),
                  title: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    widget.profile.about,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.qr_code_2_outlined),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ProfilePage(
                        profile: widget.profile,
                        client: widget.client,
                      ),
                    ),
                  ),
                );
              },
            ),
            const Divider(height: 32),
            _section('Notifications'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Notifications'),
              subtitle: Text(switch (widget.push.state) {
                PushState.ready =>
                  widget.client?.auth.currentUser == null
                      ? 'Ready. Sign in to register this device.'
                      : 'This device is registered for message alerts.',
                PushState.denied => 'Notifications are blocked. Allow them in the system settings.',
                PushState.disabled =>
                  'Off. Push setup or permission is incomplete.',
              }),
              trailing: const Icon(Icons.refresh),
              onTap: () async {
                await widget.push.initialize(widget.client);
                if (mounted) setState(() {});
              },
            ),
            _section('Privacy'),
            ValueListenableBuilder<bool>(
              valueListenable: AppLock.enabled,
              builder: (context, enabled, _) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.fingerprint),
                title: const Text('App lock'),
                subtitle: const Text('Biometric or device PIN.'),
                value: enabled,
                onChanged: (value) async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    if (!await AppLock.setEnabled(value))
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Authentication was not completed. Set up a device screen lock first.',
                          ),
                        ),
                      );
                  } catch (_) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('App lock could not be changed.'),
                      ),
                    );
                  } finally {
                    if (mounted) setState(() {});
                  }
                },
              ),
            ),
            if (AppLock.enabled.value)
              ValueListenableBuilder<Duration>(
                valueListenable: AppLock.timeout,
                builder: (context, current, _) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Automatically lock'),
                  subtitle: Text(AppLock.timeoutLabel(current)),
                  onTap: () async {
                    final picked = await showDialog<Duration>(
                      context: context,
                      builder: (ctx) => SimpleDialog(
                        title: const Text('Automatically lock'),
                        children: [
                          for (final option in AppLock.timeoutOptions)
                            SimpleDialogOption(
                              onPressed: () => Navigator.pop(ctx, option),
                              child: Row(
                                children: [
                                  if (option == current)
                                    const Icon(Icons.check, size: 18),
                                  if (option != current)
                                    const SizedBox(width: 18),
                                  const SizedBox(width: 8),
                                  Text(AppLock.timeoutLabel(option)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
                    if (picked != null) {
                      try {
                        await AppLock.setTimeout(picked);
                      } catch (_) {
                        if (context.mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Lock timer could not be changed.'),
                            ),
                          );
                      }
                    }
                  },
                ),
              ),
            _section('Chats'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.wallpaper_outlined),
              title: const Text('Default wallpaper'),
              subtitle: Text(
                ChatPreferences(
                  widget.store.preferences,
                ).defaultWallpaper.label,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final prefs = ChatPreferences(widget.store.preferences);
                final picked = await chooseChatWallpaper(
                  context,
                  prefs.defaultWallpaper,
                );
                if (picked != null) {
                  await prefs.setDefaultWallpaper(picked);
                  if (mounted) setState(() {});
                }
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.hd_outlined),
              title: const Text('HD media sharing'),
              subtitle: const Text('Higher photo quality when sharing.'),
              value: hdMedia,
              onChanged: _setHdMedia,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.data_saver_on_outlined),
              title: const Text('Use less data for calls'),
              subtitle: const Text('Lighter media profile on mobile data.'),
              value: lowDataMode,
              onChanged: _setLowData,
            ),
            if (widget.client?.auth.currentUser != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cloud_upload_outlined),
                title: const Text('Chat backup'),
                subtitle: const Text(
                  'Encrypted history in the cloud, with restore.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        BackupPage(store: widget.store, client: widget.client!),
                  ),
                ),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Media browser'),
              subtitle: const Text(
                'Browse and search encrypted media from your chats.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => EncryptedMediaBrowser(
                    store: widget.store,
                    client: widget.client!,
                  ),
                ),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy and linked devices'),
              subtitle: const Text(
                'Receipts, visibility, disappearing messages, focus and sessions.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => PrivacySettingsPage(
                    preferences: widget.store.preferences,
                    client: widget.client,
                  ),
                ),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: const Text('Chat lock'),
              subtitle: FutureBuilder<bool>(
                future: ChatLock.hasPin(),
                builder: (context, snapshot) => Text(
                  snapshot.data == true
                      ? 'PIN is set. Long-press any chat to lock it.'
                      : 'Protect chats behind a 4-digit PIN.',
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final saved = await ChatLock.promptSetup(context);
                if (saved && context.mounted) {
                  setState(() {});
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Chat lock PIN saved.')),
                  );
                }
              },
            ),
            const Divider(height: 40),
            _section('Appearance'),
            ValueListenableBuilder<AppThemeMode>(
              valueListenable: theme,
              builder: (context, mode, _) => SegmentedButton<AppThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: AppThemeMode.system,
                    label: Text('Auto'),
                    icon: Icon(Icons.brightness_auto_outlined),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {
                  mode == AppThemeMode.emerald ? AppThemeMode.dark : mode,
                },
                onSelectionChanged: (selected) =>
                    theme.setTheme(selected.first),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Auto follows this device\u2019s dark mode setting.',
              style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
            ),
            const Divider(height: 40),
            if (widget.client == null)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.cloud_off_outlined),
                  title: Text('Not connected to cloud'),
                  subtitle: Text(
                    'Chats stay on this device. Reinstall the app from the latest build to connect.',
                  ),
                ),
              ),
            if (widget.client == null)
              const SizedBox(height: 12),
            if (widget.client != null) ...[
              _section('Account'),
              if (widget.client!.auth.currentUser != null) ...[
                Text('Signed in as ${widget.client!.auth.currentUser!.email}'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => _AccountContactsRoute(
                              client: widget.client!,
                              store: widget.store,
                              push: widget.push,
                              profile: widget.profile,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('People & profile'),
                ),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                PasswordPage(client: widget.client!),
                          ),
                        ),
                  icon: const Icon(Icons.password),
                  label: const Text('Set / change OpenChat password'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            // Stop pushes for this account before signing out.
                            await widget.push.unregister(widget.client!);
                            await widget.client!.auth.signOut();
                            feedback = 'Signed out.';
                          } catch (_) {
                            feedback = 'Sign out failed. Try again.';
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                  child: const Text('Sign out'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete OpenChat account?'),
                              content: const Text(
                                'This will permanently delete your profile, contacts, and cloud account data. This action cannot be undone.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Theme.of(ctx)
                                        .colorScheme
                                        .error,
                                  ),
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Delete account'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true && mounted) {
                            setState(() => busy = true);
                            try {
                              final repo = SupabaseContactsRepository(
                                widget.client!,
                              );
                              await repo.deleteAccount();
                              feedback = 'Account deleted.';
                            } catch (e) {
                              feedback = cloudError(e);
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          }
                        },
                  child: Text(
                    'Delete account',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: email,
                  enabled: !busy,
                  autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                PasswordField(
                  controller: password,
                  enabled: !busy,
                  onSubmitted: (_) => authenticate(false),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Use your OpenChat password here. For a Google-only account, choose Continue with Google.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : () => authenticate(false),
                  child: Text(busy ? 'Please wait…' : 'Sign in'),
                ),
                TextButton(
                  onPressed: busy ? null : () => authenticate(true),
                  child: const Text('Create account'),
                ),
                const SizedBox(height: 8),
                GoogleSignInButton(
                  client: widget.client!,
                  onMessage: (message) {
                    if (mounted) setState(() => feedback = message);
                  },
                ),
                const SizedBox(height: 8),
                if (kPhoneAuthEnabled) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  PhoneAuthPage(client: widget.client!),
                            ),
                          ),
                    icon: const Icon(Icons.phone_android),
                    label: const Text('Sign in with Phone Number'),
                  ),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  RecoveryPage(client: widget.client!),
                            ),
                          ),
                    child: const Text('Forgot password?'),
                  ),
                ),
              ],
            ],
            if (feedback != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Semantics(liveRegion: true, child: Text(feedback!)),
              ),
            const Divider(height: 40),
            _section('Help'),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.info_outline),
              title: Text('About OpenChat'),
              subtitle: Text(
                'Version 1.0.0. Chats and calls are end-to-end encrypted.',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Discard account-scoped data immediately when the active identity changes.
class _AccountContactsRoute extends StatelessWidget {
  const _AccountContactsRoute({
    required this.client,
    required this.store,
    required this.push,
    required this.profile,
  });
  final SupabaseClient client;
  final ChatStore store;
  final PushService push;
  final LocalProfile profile;
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: client.auth.onAuthStateChange,
    builder: (context, snapshot) {
      final user = client.auth.currentUser;
      if (user == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Sign in required')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Your session has ended. Go back to settings and sign in.',
              ),
            ),
          ),
        );
      }
      return ContactsPage(
        key: ValueKey(user.id),
        repository: SupabaseContactsRepository(client),
        client: client,
        store: store,
        push: push,
        profile: profile,
      );
    },
  );
}
