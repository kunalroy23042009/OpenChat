import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/chat_store.dart';
import 'src/home.dart';

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
  runApp(OpenChatApp(store: store, client: client, startupError: startupError));
}

class OpenChatApp extends StatelessWidget {
  const OpenChatApp({
    super.key,
    required this.store,
    this.client,
    this.startupError,
  });
  final ChatStore store;
  final SupabaseClient? client;
  final String? startupError;
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
    home: ChatHome(store: store, client: client, startupError: startupError),
  );
}
