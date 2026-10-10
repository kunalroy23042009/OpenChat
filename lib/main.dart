import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/chat_store.dart';
import 'src/auth/password_page.dart';
import 'src/auth/recovery_controller.dart';
import 'src/home.dart';
import 'src/local_profile.dart';
import 'src/onboarding.dart';
import 'src/ops/error_report.dart';
import 'src/push/push_service.dart';

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
  final store = ChatStore(await SharedPreferences.getInstance());
  final preferences = store.preferences;
  final profile = LocalProfile(preferences);
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
  });
  final ChatStore store;
  final LocalProfile profile;
  final SharedPreferences preferences;
  final bool onboardingComplete;
  final PushService push;
  final SupabaseClient? client;
  final RecoveryController? recovery;
  final String? startupError;
  @override
  State<OpenChatApp> createState() => _OpenChatAppState();
}

class _OpenChatAppState extends State<OpenChatApp> {
  late bool entered = widget.onboardingComplete;
  final navigator = GlobalKey<NavigatorState>();
  RecoveryController? recovery;
  bool recoveryOpen = false;
  @override
  void initState() {
    super.initState();
    recovery =
        widget.recovery ??
        (widget.client == null
            ? null
            : RecoveryController(widget.client!.auth.onAuthStateChange));
    recovery?.addListener(openRecovery);
    openRecovery();
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
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    title: 'Open Chat',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF245CDB),
        primary: const Color(0xFF245CDB),
        surface: const Color(0xFFF8FAFD),
      ),
      scaffoldBackgroundColor: const Color(0xFFF8FAFD),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF8FAFD)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFEDF1F7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: entered
        ? ChatHome(
            store: widget.store,
            profile: widget.profile,
            push: widget.push,
            client: widget.client,
            startupError: widget.startupError,
          )
        : OnboardingFlow(
            profile: widget.profile,
            preferences: widget.preferences,
            client: widget.client,
            startupError: widget.startupError,
            onDone: () => setState(() => entered = true),
          ),
  );
}
