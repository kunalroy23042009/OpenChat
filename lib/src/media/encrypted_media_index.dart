import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chat_store.dart';
import '../media/media_message.dart';
import '../media/chat_media.dart';

/// Represents a single media item found in the local encrypted chat history.
class EncryptedMediaItem {
  EncryptedMediaItem({
    required this.accountId,
    required this.peerId,
    required this.peerName,
    required this.messageRef,
    required this.type,
    required this.caption,
    required this.path,
    required this.key,
    required this.nonce,
    required this.timestamp,
    this.thumbPath,
    this.thumbKey,
    this.thumbNonce,
    this.durationSec,
    this.fileName,
    this.fileSize,
    this.mine,
  });

  final String accountId;
  final String peerId;
  final String peerName;
  final String messageRef;
  final MediaType type;
  final String caption;
  final String path;
  final String key;
  final String nonce;
  final DateTime timestamp;
  final String? thumbPath;
  final String? thumbKey;
  final String? thumbNonce;
  final int? durationSec;
  final String? fileName;
  final int? fileSize;
  final bool? mine;

  String get displayName {
    if (fileName != null && fileName!.isNotEmpty) return fileName!;
    if (caption.isNotEmpty) return caption;
    return type.name;
  }
  String get displayDate {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    return '$h:$m  ${timestamp.day}/${timestamp.month}/${timestamp.year}';
  }
}

enum MediaType { image, video, voice, document }

/// Indexes and searches encrypted media from local chat history.
/// Never decrypts content during indexing - only stores metadata.
class EncryptedMediaIndex extends ChangeNotifier {
  EncryptedMediaIndex(this._store, this._chatMedia);

  final ChatStore _store;
  final ChatMedia _chatMedia;
  final Map<String, List<EncryptedMediaItem>> _byPeer = {};
  final Map<String, List<EncryptedMediaItem>> _byType = {};
  bool _indexed = false;
  DateTime? _lastRefresh;

  Map<String, List<EncryptedMediaItem>> get byPeer => Map.unmodifiable(_byPeer);
  Map<String, List<EncryptedMediaItem>> get byType => Map.unmodifiable(_byType);
  bool get isIndexed => _indexed;
  DateTime? get lastRefresh => _lastRefresh;

  /// Total count across all chats
  int get totalCount {
    int count = 0;
    for (final items in _byPeer.values) {
      count += items.length;
    }
    return count;
  }

  /// Rebuilds the index from local encrypted history.
  Future<void> buildIndex() async {
    if (_indexed) return;
    
    _byPeer.clear();
    _byType.clear();

    final accounts = _getAccounts();
    for (final accountId in accounts) {
      await _indexAccount(accountId);
    }

    _indexed = true;
    _lastRefresh = DateTime.now();
    notifyListeners();
  }

  /// Refreshes the index (for new messages).
  Future<void> refresh() async {
    _byPeer.clear();
    _byType.clear();
    _indexed = false;
    await buildIndex();
  }

  List<String> _getAccounts() {
    final prefs = _store.preferences;
    final keys = prefs.getKeys().where((k) => k.startsWith('openchat.secure.v1.')).toSet();
    final accounts = <String>{};
    for (final key in keys) {
      final parts = key.split('-');
      if (parts.length >= 3) {
        accounts.add(parts[1]); // accountId is the second part after prefix
      }
    }
    return accounts.toList();
  }

  Future<void> _indexAccount(String accountId) async {
    // Get all peer IDs from secure history keys
    final prefs = _store.preferences;
    final prefix = 'openchat.secure.v1.$accountId-';
    final peerKeys = prefs.getKeys().where((k) => k.startsWith(prefix)).toSet();
    
    for (final key in peerKeys) {
      final peerId = key.substring(prefix.length);
      // Use peerId as fallback name; actual names resolved in UI
      final peerName = peerId;
      
      await _indexPeer(accountId, peerId, peerName);
    }
  }

  Future<void> _indexPeer(String accountId, String peerId, String peerName) async {
    final messages = _store.getSecureConversation(accountId, peerId);
    if (messages.isEmpty) return;

    final items = <EncryptedMediaItem>[];
    
    for (final msg in messages) {
      if (msg.mine != true) continue; // Only index our messages for media we can decrypt
      
      final body = parseMessageBody(msg.text);
      EncryptedMediaItem? item;
      
      if (body.isImage && body.path != null && body.key != null && body.nonce != null) {
        item = EncryptedMediaItem(
          accountId: accountId,
          peerId: peerId,
          peerName: peerName,
          messageRef: msg.ref,
          type: MediaType.image,
          caption: body.text,
          path: body.path!,
          key: body.key!,
          nonce: body.nonce!,
          timestamp: msg.at,
          mine: true,
        );
      } else if (body.isVideo && body.path != null && body.key != null && body.nonce != null) {
        item = EncryptedMediaItem(
          accountId: accountId,
          peerId: peerId,
          peerName: peerName,
          messageRef: msg.ref,
          type: MediaType.video,
          caption: body.text,
          path: body.path!,
          key: body.key!,
          nonce: body.nonce!,
          timestamp: msg.at,
          thumbPath: body.thumbPath,
          thumbKey: body.thumbKey,
          thumbNonce: body.thumbNonce,
          durationSec: body.durationSec,
          mine: true,
        );
      } else if (body.isVoice && body.path != null && body.key != null && body.nonce != null) {
        item = EncryptedMediaItem(
          accountId: accountId,
          peerId: peerId,
          peerName: peerName,
          messageRef: msg.ref,
          type: MediaType.voice,
          caption: 'Voice note (${body.durationSec}s)',
          path: body.path!,
          key: body.key!,
          nonce: body.nonce!,
          timestamp: msg.at,
          durationSec: body.durationSec,
          mine: true,
        );
      } else if (body.isDocument && body.path != null && body.key != null && body.nonce != null) {
        item = EncryptedMediaItem(
          accountId: accountId,
          peerId: peerId,
          peerName: peerName,
          messageRef: msg.ref,
          type: MediaType.document,
          caption: body.fileName,
          path: body.path!,
          key: body.key!,
          nonce: body.nonce!,
          timestamp: msg.at,
          fileName: body.fileName,
          fileSize: body.byteLength,
          mine: true,
        );
      }
      
      if (item != null) {
        items.add(item);
      }
    }

    if (items.isNotEmpty) {
      _byPeer['$accountId-$peerId'] = items;
      for (final item in items) {
        final typeKey = item.type.name;
        _byType.putIfAbsent(typeKey, () => []).add(item);
      }
    }
  }

  /// Search media by caption/filename across all chats.
  List<EncryptedMediaItem> search(String query) {
    if (query.trim().isEmpty) return [];
    final q = query.toLowerCase();
    final results = <EncryptedMediaItem>[];
    for (final items in _byPeer.values) {
      for (final item in items) {
        if (item.caption.toLowerCase().contains(q) ||
            (item.fileName?.toLowerCase().contains(q) ?? false)) {
          results.add(item);
        }
      }
    }
    results.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return results;
  }

  /// Get media for a specific peer.
  List<EncryptedMediaItem> getMediaForPeer(String accountId, String peerId) {
    return _byPeer['$accountId-$peerId'] ?? [];
  }

  /// Get media by type (image, video, voice, document).
  List<EncryptedMediaItem> getMediaByType(MediaType type) {
    return _byType[type.name] ?? [];
  }

  /// Decrypts and returns the media bytes for an item.
  Future<Uint8List?> decryptMedia(EncryptedMediaItem item) async {
    try {
      return await _chatMedia.downloadSealed(item.path, item.key, item.nonce);
    } catch (_) {
      return null;
    }
  }

  /// Decrypts and returns video bytes for an item.
  Future<Uint8List?> decryptVideo(EncryptedMediaItem item) async {
    try {
      return await _chatMedia.downloadSealedVideo(item.path, item.key, item.nonce);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _byPeer.clear();
    _byType.clear();
    super.dispose();
  }
}