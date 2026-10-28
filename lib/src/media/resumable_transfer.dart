import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

/// Checkpoint for resumable uploads/downloads.
class TransferCheckpoint {
  TransferCheckpoint({
    required this.objectPath,
    required this.totalSize,
    required this.uploadedBytes,
    required this.lastUpdated,
    this.chunkSize = 4 * 1024 * 1024, // 4 MiB default
  });
  final String objectPath;
  final int totalSize;
  int uploadedBytes;
  final DateTime lastUpdated;
  final int chunkSize;

  Map<String, dynamic> toJson() => {
        'objectPath': objectPath,
        'totalSize': totalSize,
        'uploadedBytes': uploadedBytes,
        'lastUpdated': lastUpdated.toIso8601String(),
        'chunkSize': chunkSize,
      };

  factory TransferCheckpoint.fromJson(Map<String, dynamic> json) =>
      TransferCheckpoint(
        objectPath: json['objectPath'] as String,
        totalSize: json['totalSize'] as int,
        uploadedBytes: json['uploadedBytes'] as int,
        lastUpdated: DateTime.parse(json['lastUpdated'] as String),
        chunkSize: json['chunkSize'] as int? ?? 4 * 1024 * 1024,
      );
}

/// Manages resumable upload/download checkpoints in local storage.
class TransferCheckpointManager {
  TransferCheckpointManager(this._prefs);
  final SharedPreferences _prefs;
  static const _prefix = 'openchat.transfer_checkpoint.v1.';

  /// Save checkpoint for an upload.
  Future<void> saveUploadCheckpoint(TransferCheckpoint cp) async {
    await _prefs.setString('${_prefix}up:${cp.objectPath}', jsonEncode(cp.toJson()));
  }

  /// Save checkpoint for a download.
  Future<void> saveDownloadCheckpoint(TransferCheckpoint cp) async {
    await _prefs.setString('${_prefix}dl:${cp.objectPath}', jsonEncode(cp.toJson()));
  }

  /// Get upload checkpoint if exists and not stale (>24h).
  TransferCheckpoint? getUploadCheckpoint(String objectPath) {
    final json = _prefs.getString('${_prefix}up:$objectPath');
    if (json == null) return null;
    try {
      final cp = TransferCheckpoint.fromJson(jsonDecode(json) as Map<String, dynamic>);
      if (DateTime.now().difference(cp.lastUpdated) > const Duration(hours: 24)) {
        clearUploadCheckpoint(objectPath);
        return null;
      }
      return cp;
    } catch (_) {
      clearUploadCheckpoint(objectPath);
      return null;
    }
  }

  /// Get download checkpoint if exists and not stale (>24h).
  TransferCheckpoint? getDownloadCheckpoint(String objectPath) {
    final json = _prefs.getString('${_prefix}dl:$objectPath');
    if (json == null) return null;
    try {
      final cp = TransferCheckpoint.fromJson(jsonDecode(json) as Map<String, dynamic>);
      if (DateTime.now().difference(cp.lastUpdated) > const Duration(hours: 24)) {
        clearDownloadCheckpoint(objectPath);
        return null;
      }
      return cp;
    } catch (_) {
      clearDownloadCheckpoint(objectPath);
      return null;
    }
  }

  /// Clear upload checkpoint.
  Future<void> clearUploadCheckpoint(String objectPath) async {
    await _prefs.remove('${_prefix}up:$objectPath');
  }

  /// Clear download checkpoint.
  Future<void> clearDownloadCheckpoint(String objectPath) async {
    await _prefs.remove('${_prefix}dl:$objectPath');
  }
}

/// Resumable upload using Supabase Storage (simulated with local checkpoint tracking).
/// For true resumable uploads, we'd need TUS support. This implementation provides local
/// checkpoint tracking so the app can resume from the last completed chunk on restart.
class ResumableUploader {
  ResumableUploader({
    required this.client,
    required this.bucket,
    required this.checkpoints,
    this.chunkSize = 4 * 1024 * 1024,
  });
  final SupabaseClient client;
  final String bucket;
  final TransferCheckpointManager checkpoints;
  final int chunkSize;

  /// Upload with resume support. Returns the final object path.
  Future<String> upload(
    String objectPath,
    Uint8List data, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final existingCp = checkpoints.getUploadCheckpoint(objectPath);
    int startOffset = 0;
    if (existingCp != null && existingCp.uploadedBytes < existingCp.totalSize) {
      startOffset = existingCp.uploadedBytes;
    }

    final totalChunks = (data.length + chunkSize - 1) ~/ chunkSize;
    int completedChunks = startOffset ~/ chunkSize;

    for (int i = completedChunks; i < totalChunks; i++) {
      if (isCancelled?.call() == true) {
        // Save checkpoint before exit
        await checkpoints.saveUploadCheckpoint(TransferCheckpoint(
          objectPath: objectPath,
          totalSize: data.length,
          uploadedBytes: i * chunkSize,
          lastUpdated: DateTime.now(),
          chunkSize: chunkSize,
        ));
        throw StateError('Upload cancelled');
      }

      final start = i * chunkSize;
      final end = (start + chunkSize < data.length) ? start + chunkSize : data.length;

      // Upload full object (Supabase doesn't support true resumable; we track local progress)
      await client.storage.from(bucket).uploadBinary(objectPath, data);

      await checkpoints.saveUploadCheckpoint(TransferCheckpoint(
        objectPath: objectPath,
        totalSize: data.length,
        uploadedBytes: end,
        lastUpdated: DateTime.now(),
        chunkSize: chunkSize,
      ));

      onProgress?.call(end / data.length);
    }

    await checkpoints.clearUploadCheckpoint(objectPath);
    return objectPath;
  }
}

/// Resumable download using HTTP Range headers.
class ResumableDownloader {
  ResumableDownloader({
    required this.client,
    required this.bucket,
    required this.checkpoints,
    required this.supabaseUrl,
    required this.supabaseKey,
  });
  final SupabaseClient client;
  final String bucket;
  final TransferCheckpointManager checkpoints;
  final String supabaseUrl;
  final String supabaseKey;

  /// Download with resume support. Returns the complete file bytes.
  Future<Uint8List> download(
    String objectPath,
    int totalSize, {
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final existingCp = checkpoints.getDownloadCheckpoint(objectPath);
    final file = File('${Directory.systemTemp.path}/dl_${objectPath.replaceAll('/', '_')}');
    final raf = file.openSync(mode: FileMode.write);

    int downloaded = 0;
    if (existingCp != null && existingCp.uploadedBytes < existingCp.totalSize) {
      downloaded = existingCp.uploadedBytes;
      // Pre-allocate file
      if (downloaded > 0) {
        raf.writeFromSync(Uint8List(downloaded), 0);
      }
    }

    const chunkSize = 4 * 1024 * 1024;
    final totalChunks = (totalSize + chunkSize - 1) ~/ chunkSize;
    int startChunk = downloaded ~/ chunkSize;

    for (int i = startChunk; i < totalChunks; i++) {
      if (isCancelled?.call() == true) {
        await checkpoints.saveDownloadCheckpoint(TransferCheckpoint(
          objectPath: objectPath,
          totalSize: totalSize,
          uploadedBytes: downloaded,
          lastUpdated: DateTime.now(),
        ));
        await raf.close();
        throw StateError('Download cancelled');
      }

      final start = i * chunkSize;
      final end = (start + chunkSize < totalSize) ? start + chunkSize : totalSize;
      final range = '$start-${end - 1}';

      // Use Supabase REST API with Range header
      final url = '$supabaseUrl/storage/v1/object/$bucket/$objectPath';
      final token = client.auth.currentSession?.accessToken ?? '';
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
          'apikey': supabaseKey,
          'Range': 'bytes=$range',
        },
      );

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw StateError('Download failed: ${response.statusCode}');
      }

      final chunk = response.bodyBytes;
      raf.writeFromSync(chunk, downloaded);
      downloaded += chunk.length;

      await checkpoints.saveDownloadCheckpoint(TransferCheckpoint(
        objectPath: objectPath,
        totalSize: totalSize,
        uploadedBytes: downloaded,
        lastUpdated: DateTime.now(),
      ));

      onProgress?.call(downloaded / totalSize);
    }

    await raf.close();
    final complete = await file.readAsBytes();
    await checkpoints.clearDownloadCheckpoint(objectPath);
    await file.delete();
    return complete;
  }
}