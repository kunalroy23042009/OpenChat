import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/chat_store.dart';
import 'src/home.dart';
import 'src/local_profile.dart';
import 'src/onboarding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  final store = ChatStore(await SharedPreferences.getInstance());
  final preferences = store.preferences;
  final profile = LocalProfile(preferences);
  final onboarded = preferences.getBool('openchat.onboarding.v1') ?? false;
  runApp(
    OpenChatApp(
      store: store,
      profile: profile,
      preferences: preferences,
      onboardingComplete: onboarded,
      client: client,
      startupError: startupError,
    ),
  );
}

class OpenChatApp extends StatefulWidget {
  const OpenChatApp({
    super.key,
    required this.store,
    required this.profile,
    required this.preferences,
    required this.onboardingComplete,
    this.client,
    this.startupError,
  });
  final ChatStore store;
  final LocalProfile profile;
  final SharedPreferences preferences;
  final bool onboardingComplete;
  final SupabaseClient? client;
  final String? startupError;
  @override
  State<OpenChatApp> createState() => _OpenChatAppState();
}

class _OpenChatAppState extends State<OpenChatApp> {
  late bool entered = widget.onboardingComplete;
  @override
  Widget build(BuildContext context) => MaterialApp(
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
