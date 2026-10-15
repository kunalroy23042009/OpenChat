import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal Google Drive backup backend using the hidden `appDataFolder`.
/// WhatsApp-style: same encrypted `OCBK1` blob as Supabase, but stored in
/// the user's Drive so reinstalls can restore without Supabase.
/// Media bytes stay in Supabase `chat-media` for v1 and re-download on
/// demand; the blob holds history + stars/pins/drafts/reactions + groups.
class GoogleDriveBackup {
  static const _scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const _filesUrl = 'https://www.googleapis.com/drive/v3/files';
  static const _uploadUrl =
      'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart';

  static final GoogleSignIn _signIn = GoogleSignIn(scopes: [_scope]);

  static Future<Map<String, String>> _headers() async {
    var account = _signIn.currentUser ?? await _signIn.signInSilently();
    account ??= await _signIn.signIn();
    if (account == null) {
      throw StateError('Google sign-in required for Drive backup.');
    }
    final headers = await account.authHeaders;
    return Map<String, String>.from(headers);
  }

  static Future<bool> isSignedIn() => _signIn.isSignedIn();

  static String? currentEmail() => _signIn.currentUser?.email;

  static Future<void> signOut() => _signIn.signOut();

  static Future<void> ensureSignedIn() async {
    await _headers();
  }

  static String fileName(String uid, String snapshotId) =>
      'openchat_$uid backup_$snapshotId.enc'.replaceAll(' ', '_');

  /// Newest-first Drive backup files for this app.
  static Future<List<Map<String, dynamic>>> listBackups() async {
    final headers = await _headers();
    final uri = Uri.parse(
      '$_filesUrl?q=${Uri.encodeComponent("trashed=false")}'
      '&spaces=appDataFolder'
      '&fields=files(id,name,createdTime,modifiedTime,size)'
      '&orderBy=modifiedTime desc'
      '&pageSize=20',
    );
    final res = await http.get(uri, headers: headers);
    if (res.statusCode != 200) {
      throw StateError('Drive list failed (${res.statusCode}).');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return ((body['files'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Uploads one sealed backup blob. Returns the Drive file id.
  static Future<String> uploadBackupBytes(
    Uint8List bytes,
    String name,
  ) async {
    final headers = await _headers();
    final metadata = jsonEncode({
      'name': name,
      'parents': ['appDataFolder'],
      'mimeType': 'application/octet-stream',
    });
    final request = http.MultipartRequest('POST', Uri.parse(_uploadUrl))
      ..headers.addAll(headers)
      ..fields['metadata'] =
          metadata; // fallback; real metadata sent as separate part below
    // Build multipart manually: metadata JSON + binary media.
    final boundary =
        'openchat-${DateTime.now().microsecondsSinceEpoch}';
    final body = BytesBuilder(copy: false)
      ..add(utf8.encode('--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$metadata\r\n'
          '--$boundary\r\n'
          'Content-Type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final raw = await http.post(
      Uri.parse(_uploadUrl),
      headers: {
        ...headers,
        'Content-Type': 'multipart/related; boundary=$boundary',
      },
      body: body.takeBytes(),
    );
    if (raw.statusCode != 200) {
      // Surface auth/config issues (e.g. missing SHA-1 / API not enabled).
      throw StateError(
        'Drive upload failed (${raw.statusCode}). '
        'Check SHA-1 + Drive API enabled. ${raw.body}',
      );
    }
    final created = jsonDecode(raw.body) as Map<String, dynamic>;
    final id = created['id'] as String?;
    if (id == null || id.isEmpty) throw StateError('Drive upload failed.');
    // request unused; kept to avoid MultipartRequest validation overhead.
    request.fields.clear();
    return id;
  }

  static Future<Uint8List> downloadBackup(String fileId) async {
    final headers = await _headers();
    final uri = Uri.parse('$_filesUrl/$fileId?alt=media');
    final res = await http.get(uri, headers: headers);
    if (res.statusCode != 200) {
      throw StateError('Drive download failed (${res.statusCode}).');
    }
    return res.bodyBytes;
  }

  static Future<void> deleteBackup(String fileId) async {
    final headers = await _headers();
    final res = await http.delete(
      Uri.parse('$_filesUrl/$fileId'),
      headers: headers,
    );
    if (res.statusCode != 204 && res.statusCode != 200) {
      throw StateError('Drive delete failed (${res.statusCode}).');
    }
  }

  static Future<void> pruneOld(int keep) async {
    final files = await listBackups();
    if (files.length <= keep) return;
    for (var i = keep; i < files.length; i++) {
      final id = files[i]['id'] as String?;
      if (id != null && id.isNotEmpty) {
        try {
          await deleteBackup(id);
        } catch (_) {}
      }
    }
  }

  // ---- WhatsApp-style backup policy (per account) ----
  static String _excludeVideosKey(String uid) =>
      'openchat.drive.excludeVideos.v1.$uid';
  static String _cellularKey(String uid) =>
      'openchat.drive.overCellular.v1.$uid';

  /// When true, video blobs are skipped from cloud media copies to save
  /// Drive space. Message history is always included.
  static bool excludeVideos(SharedPreferences prefs, String uid) =>
      prefs.getBool(_excludeVideosKey(uid)) ?? false;

  static Future<void> setExcludeVideos(
    SharedPreferences prefs,
    String uid,
    bool value,
  ) =>
      prefs.setBool(_excludeVideosKey(uid), value);

  /// When false (default WhatsApp behavior), cloud uploads run on Wi-Fi
  /// only. Cellular uploads need an explicit opt-in.
  static bool allowCellular(SharedPreferences prefs, String uid) =>
      prefs.getBool(_cellularKey(uid)) ?? false;

  static Future<void> setAllowCellular(
    SharedPreferences prefs,
    String uid,
    bool value,
  ) =>
      prefs.setBool(_cellularKey(uid), value);

  /// True when the current network is unmetered Wi-Fi/Ethernet, or the user
  /// explicitly allowed cellular backups.
  static Future<bool> networkAllowed(
    SharedPreferences prefs,
    String uid,
  ) async {
    try {
      final nets = await Connectivity().checkConnectivity();
      final wifi = nets.any(
        (n) =>
            n == ConnectivityResult.wifi || n == ConnectivityResult.ethernet,
      );
      if (wifi) return true;
      if (nets.contains(ConnectivityResult.none)) return false;
      return allowCellular(prefs, uid);
    } catch (_) {
      return true;
    }
  }
}
