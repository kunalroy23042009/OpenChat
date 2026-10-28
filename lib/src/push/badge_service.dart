import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';

import '../chat_store.dart';
import '../chat/conversation_repository.dart';
import '../chat/direct_unread.dart';

/// Service for managing the app icon badge counter.
/// Aggregates unread counts from direct messages, groups, and status updates.
class BadgeService {
  BadgeService._internal(this._store, this._repo, this._directUnread);

  final ChatStore _store;
  final ConversationRepository _repo;
  final DirectUnread _directUnread;

  static BadgeService? _instance;

  static BadgeService? get instance => _instance;

  static bool get isInitialized => _instance != null;

  static Future<void> initialize({
    required ChatStore store,
    required ConversationRepository repo,
    required DirectUnread directUnread,
  }) async {
    _instance = BadgeService._internal(store, repo, directUnread);
    await _instance!._loadInitialCounts();
  }

  Timer? _updateTimer;
  int _lastBadgeCount = 0;
  int _directUnreadTotal = 0;
  int _groupUnreadTotal = 0;
  int _statusUnreadTotal = 0;

  Future<void> _loadInitialCounts() async {
    _directUnread.addListener(_onDirectUnreadChanged);
    _repo.addListener(_onGroupConversationsChanged);
    _store.addListener(_onStoreChanged);

    // Initial counts
    _directUnreadTotal = _directUnread.counts.values.fold(0, (a, b) => a + b);
    await _refreshGroupUnreadTotal();
    _statusUnreadTotal = 0; // Status unread tracking would need separate implementation
    _updateBadge();
  }

  void _onDirectUnreadChanged() {
    _directUnreadTotal = _directUnread.counts.values.fold(0, (a, b) => a + b);
    _updateBadge();
  }

  void _onGroupConversationsChanged() {
    _refreshGroupUnreadTotal();
  }

  void _onStoreChanged() {
    // Could check for status unread changes here
    _updateBadge();
  }

  Future<void> _refreshGroupUnreadTotal() async {
    try {
      int total = 0;
      for (final conv in _repo.conversations) {
        if (!conv.isArchived && conv.unreadCount > 0) {
          total += conv.unreadCount;
        }
      }
      _groupUnreadTotal = total;
      _updateBadge();
    } catch (_) {
      // Ignore errors during refresh
    }
  }

  /// Updates the badge count based on total unread messages.
  Future<void> _updateBadge() async {
    try {
      if (kIsWeb) return;
      if (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS) {
        return;
      }

      final totalUnread = _directUnreadTotal + _groupUnreadTotal + _statusUnreadTotal;

      if (totalUnread != _lastBadgeCount) {
        _lastBadgeCount = totalUnread;
        if (totalUnread > 0) {
          await FlutterAppBadger.updateBadgeCount(totalUnread);
        } else {
          await FlutterAppBadger.removeBadge();
        }
        debugPrint('BadgeService: Badge updated to $totalUnread (direct=$_directUnreadTotal, group=$_groupUnreadTotal, status=$_statusUnreadTotal)');
      }
    } catch (e) {
      debugPrint('BadgeService: Failed to update badge: $e');
    }
  }

  /// Updates the badge count immediately (call after message send/receive).
  Future<void> refresh() async {
    _directUnreadTotal = _directUnread.counts.values.fold(0, (a, b) => a + b);
    await _refreshGroupUnreadTotal();
    _updateBadge();
  }

  void dispose() {
    _updateTimer?.cancel();
    _directUnread.removeListener(_onDirectUnreadChanged);
    _repo.removeListener(_onGroupConversationsChanged);
    _store.removeListener(_onStoreChanged);
  }
}