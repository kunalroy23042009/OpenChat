import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/avatar_sync.dart';
import 'src/chat_store.dart';
import 'src/auth/password_page.dart';
import 'src/auth/recovery_controller.dart';
import 'src/home.dart';
import 'src/local_profile.dart';
import 'src/onboarding.dart';
import 'src/ops/error_report.dart';
import 'src/push/push_service.dart';
import 'src/theme/app_theme.dart';
import 'src/security/app_lock.dart';
import 'src/security/secure_history_database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Content-free crash breadcrumbs for pilot ops. No message bodies,
  // ciphertext, or key material ever leaves the device through this path.
  ErrorReport.install();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  String? startupError;
  SupabaseClient? client;
  if (url.isNotEmpty && key.isNotEmpty) {
    try {
      await Supabase.initialize(url: url, publishableKey: key);
      client = Supabase.instance.client;
    } catch (_) {
      startupError =
          'Backend connection failed. Check your Supabase configuration.';
    }
  }
  final recovery = client == null
      ? null
      : RecoveryController(client.auth.onAuthStateChange);
  final preferences = await SharedPreferences.getInstance();
  final secureHistory = SecureHistoryDatabase();
  await secureHistory.initialize(preferences);
  final store = ChatStore(
    preferences,
    purgeDemoSeeds: true,
    secureHistory: secureHistory,
  );
  final profile = LocalProfile(preferences);
  final theme = AppThemeController(preferences);
  final onboarded = preferences.getBool('openchat.onboarding.v1') ?? false;
  final push = PushService();
  runApp(
    OpenChatApp(
      store: store,
      profile: profile,
      preferences: preferences,
      onboardingComplete: onboarded,
      push: push,
      client: client,
      recovery: recovery,
      startupError: startupError,
      theme: theme,
    ),
  );
  // Push registration must never block or break startup.
  push.initialize(client);
}

class OpenChatApp extends StatefulWidget {
  const OpenChatApp({
    super.key,
    required this.store,
    required this.profile,
    required this.preferences,
    required this.onboardingComplete,
    required this.push,
    this.client,
    this.recovery,
    this.startupError,
    this.theme,
  });
  final ChatStore store;
  final LocalProfile profile;
  final SharedPreferences preferences;
  final bool onboardingComplete;
  final PushService push;
  final SupabaseClient? client;
  final RecoveryController? recovery;
  final String? startupError;
  final AppThemeController? theme;
  @override
  State<OpenChatApp> createState() => _OpenChatAppState();
}

class _OpenChatAppState extends State<OpenChatApp> {
  late bool entered = widget.onboardingComplete;
  late AppThemeController theme;
  final navigator = GlobalKey<NavigatorState>();
  RecoveryController? recovery;
  bool recoveryOpen = false;
  @override
  void initState() {
    super.initState();
    theme = widget.theme ?? AppThemeController(widget.preferences);
    recovery =
        widget.recovery ??
        (widget.client == null
            ? null
            : RecoveryController(widget.client!.auth.onAuthStateChange));
    recovery?.addListener(openRecovery);
    openRecovery();
    
    // Listen for auth changes to sync avatar
    widget.client?.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.signedIn && data.session != null) {
        final avatarSync = AvatarSyncService(
          client: widget.client!,
          preferences: widget.preferences,
        );
        avatarSync.onSignIn(widget.profile);
        // Register/refresh the FCM token the moment we have a session, so
        // background notifications work without waiting for Settings.
        if (widget.push.state != PushState.ready) {
          await widget.push.initialize(widget.client);
        } else {
          await widget.push.syncAccount(widget.client!);
        }
      }
    });
  }

  void openRecovery() {
    if (recoveryOpen || recovery?.accountId == null || widget.client == null) {
      return;
    }
    recoveryOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final accountId = recovery?.accountId;
      recovery?.consume();
      if (accountId != null &&
          widget.client!.auth.currentUser?.id == accountId) {
        await navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                PasswordPage(client: widget.client!, recovery: true),
          ),
        );
      }
      recoveryOpen = false;
    });
  }

  @override
  void dispose() {
    recovery?.removeListener(openRecovery);
    recovery?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppThemeMode>(
    valueListenable: theme,
    builder: (context, mode, _) => MaterialApp(
      navigatorKey: navigator,
      title: 'OpenChat',
      debugShowCheckedModeBanner: false,
      theme: theme.lightTheme,
      darkTheme: mode == AppThemeMode.emerald
          ? theme.emeraldTheme
          : theme.darkTheme,
      themeMode: theme.themeMode,
      builder: (context, child) =>
          AppLockGate(child: child ?? const SizedBox()),
      home: entered
          ? ChatHome(
              store: widget.store,
              profile: widget.profile,
              push: widget.push,
              client: widget.client,
              startupError: widget.startupError,
              theme: theme,
            )
          : OnboardingFlow(
              profile: widget.profile,
              preferences: widget.preferences,
              client: widget.client,
              startupError: widget.startupError,
              onDone: () => setState(() => entered = true),
            ),
    ),
  );
}
