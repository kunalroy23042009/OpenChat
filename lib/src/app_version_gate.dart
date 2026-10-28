import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Compares dotted version names numerically ('1.10.2' > '1.9.0'). Build
/// metadata after '+' is ignored: the gate keys on versionName only.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p.trim()) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// The server's minimum supported versionName, or null when unconfigured /
/// unreachable — callers must fail open on null so nobody is ever locked
/// out by a broken gate.
Future<String?> fetchMinAppVersion(SupabaseClient client) async {
  final row = await client
      .from('app_config')
      .select('value')
      .eq('key', 'min_app_version')
      .maybeSingle();
  final value = row?['value'];
  return value is String && value.isNotEmpty ? value : null;
}

/// Full-screen gate shown when the installed app is older than the
/// server's minimum supported version. Same visual language as the chat
/// screens (dark slate + WhatsApp green).
class AppUpdateGate extends StatelessWidget {
  const AppUpdateGate({
    super.key,
    required this.currentVersion,
    required this.minVersion,
    required this.onRecheck,
  });

  final String currentVersion;
  final String minVersion;
  final Future<void> Function() onRecheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0B141A) : const Color(0xFFECE5DD),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.system_update_alt_rounded,
                  size: 72,
                  color: Color(0xFF00A884),
                ),
                const SizedBox(height: 24),
                Text(
                  'Update OpenChat',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'This version is too old to work with the latest server. '
                  'Install the newest OpenChat APK, then reopen the app.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.4,
                    color: fg.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Installed: $currentVersion\nRequired: $minVersion',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: fg.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: onRecheck,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text("I've updated — recheck"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
