import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/theme/app_theme.dart';
import 'src/chat/chat_preferences.dart';
import 'src/chat/conversation_repository.dart';
import 'src/media/media_message.dart';
import 'src/widgets/message_format.dart';
import 'src/avatar_sync.dart';
import 'src/local_profile.dart';
import 'src/onboarding.dart';
import 'src/home.dart';
import 'src/settings.dart';
import 'src/secure_chat_screen.dart';
import 'src/contacts_page.dart';
import 'src/profile_page.dart';
import 'src/status/status_page.dart';
import 'src/calling/call_screen.dart';
import 'src/auth/phone_auth.dart';
import 'src/auth/password_page.dart';
import 'src/auth/recovery_controller.dart';
import 'src/push/push_service.dart';
import 'src/push/notify_service.dart';
import 'src/security/app_lock.dart';
import 'src/backup/backup_page.dart';
import 'src/privacy_settings_page.dart';
import 'src/ops/error_report.dart';
import 'src/web_init.dart';

const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const String giphyApiKey = String.fromEnvironment('GIPHY_API_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize web-specific services
  if (kIsWeb) {
    await initializeWebServices();
  }
  
  // Content-free crash breadcrumbs for pilot ops
  ErrorReport.install();
  
  // Initialize Supabase
  SupabaseClient? client;
  String? startupError;
  if (supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabaseAnonKey,
      );
      client = Supabase.instance.client;
    } catch (_) {
      startupError = 'Backend connection failed. Check your Supabase configuration.';
    }
  }
  
  final preferences = await SharedPreferences.getInstance();
  final chatPrefs = ChatPreferences(preferences);
  final profile = LocalProfile(preferences);
  final onboarded = preferences.getBool('openchat.onboarding.v1') ?? false;
  final push = PushService();
  final theme = AppThemeController(preferences);
  
  // Recovery controller for password reset deep links
  final recovery = client == null
      ? null
      : RecoveryController(client.auth.onAuthStateChange);
  
  runApp(
    OpenChatWebApp(
      profile: profile,
      preferences: preferences,
      onboardingComplete: onboarded,
      push: push,
      client: client,
      recovery: recovery,
      startupError: startupError,
      theme: theme,
      chatPrefs: chatPrefs,
    ),
  );
  
  // Initialize push service
  push.initialize(client);
  
  // Initialize notification service
  if (client != null) {
    await NotifyService.instance.initialize(client);
  }
}

class OpenChatWebApp extends StatefulWidget {
  const OpenChatWebApp({
    super.key,
    required this.profile,
    required this.preferences,
    required this.onboardingComplete,
    required this.push,
    this.client,
    this.recovery,
    this.startupError,
    required this.theme,
    required this.chatPrefs,
  });
  
  final LocalProfile profile;
  final SharedPreferences preferences;
  final bool onboardingComplete;
  final PushService push;
  final SupabaseClient? client;
  final RecoveryController? recovery;
  final String? startupError;
  final AppThemeController theme;
  final ChatPreferences chatPrefs;
  
  @override
  State<OpenChatWebApp> createState() => _OpenChatWebAppState();
}

class _OpenChatWebAppState extends State<OpenChatWebApp> {
  late bool entered = widget.onboardingComplete;
  late AppThemeController theme;
  final navigator = GlobalKey<NavigatorState>();
  RecoveryController? recovery;
  bool recoveryOpen = false;
  
  @override
  void initState() {
    super.initState();
    theme = widget.theme;
    recovery = widget.recovery ?? (widget.client == null
        ? null
        : RecoveryController(widget.client!.auth.onAuthStateChange));
    recovery?.addListener(openRecovery);
    openRecovery();
    
    // Listen for auth changes
    widget.client?.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.signedIn && data.session != null) {
        // Register/refresh FCM token
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
            builder: (_) => PasswordPage(client: widget.client!, recovery: true),
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
      builder: (context, child) => AppLockGate(child: child ?? const SizedBox()),
      home: entered
          ? ChatHome(
              profile: widget.profile,
              push: widget.push,
              client: widget.client,
              startupError: widget.startupError,
              theme: theme,
              chatPrefs: widget.chatPrefs,
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