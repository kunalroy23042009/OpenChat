import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dart:async';

import 'package:flutter_contacts/flutter_contacts.dart';

import 'chat_store.dart';
import 'chat/direct_unread.dart';
import 'chat_lock.dart';
import 'chat_preferences.dart';
import 'contacts_repository.dart';
import 'contacts_page.dart';
import 'contacts_sync.dart';
import 'local_profile.dart';
import 'media/media_message.dart';
import 'profile_page.dart';
import 'push/badge_service.dart';
import 'push/push_service.dart';
import 'push/notify_service.dart';
import 'secure_chat_screen.dart';
import 'settings.dart';
import 'theme/app_theme.dart';
import 'status/status_page.dart';
import 'app_version_gate.dart';
import 'calling/call_history_page.dart';
import 'calling/call_repository.dart';
import 'calling/call_service.dart';
import 'calling/call_signaling.dart';
import 'calling/call_screen.dart';
import 'calling/native_call_service.dart' hide CallType;
import 'calling/group_voice_chat.dart';
import 'backup/chat_backup.dart';
import 'backup/google_drive_backup.dart';
import 'chat/conversation_repository.dart';
import 'chat/group_chat_screen.dart';
import 'chat/profile_watcher.dart';
import 'ops/error_report.dart';
import 'security/secure_history_database.dart';
import 'security/signal_crypto.dart';
import 'widgets/whatsapp_bubble.dart';
import 'widgets/status_ticks.dart';
import 'widgets/whatsapp_wallpaper.dart';
import 'features_page.dart';
import 'broadcast/broadcast_lists.dart';
import 'package:package_info_plus/package_info_plus.dart';

class ChatHome extends StatefulWidget {
  const ChatHome({
    super.key,
    required this.store,
    required this.profile,
    required this.push,
    this.client,
    this.startupError,
    this.theme,
  });
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  final SupabaseClient? client;
  final String? startupError;
  final AppThemeController? theme;
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> with WidgetsBindingObserver {
  final _groupsKey = GlobalKey<_GroupSectionState>();
  Conversation? selected;
  String query = '';
  String filter = 'all';
  bool lockRevealed = false;
  bool archivedOpen = false;
  RealtimeChannel? _callWatch;
  String? _callWatchUid;
  bool _incomingOpen = false;

  // Native (Telecom) ring supervision for the invite currently ringing.
  RealtimeChannel? _ringWatch;
  Timer? _ringTimer;
  Future<void> Function()? _ringSettle;

  RealtimeChannel? _notifyWatch;
  String? _notifyUid;
  Map<String, String> _notifyNames = {};

  /// Server-driven version gate: when the installed app is older than
  /// `app_config.min_app_version`, the whole UI is replaced by an update
  /// screen. Fails open — an unreachable gate never blocks anyone.
  bool _updateRequired = false;
  String? _minAppVersion;
  String? _installedAppVersion;
  String? _versionCheckedForUid;
  int activeTab = 0;
  late final BroadcastListService _broadcastService = BroadcastListService(
    widget.store.preferences,
  );

  // Shared instances for badge aggregation
  DirectUnread? _directUnread;
  ConversationRepository? _conversationRepo;

  void open(Conversation chat, bool wide) {
    widget.store.markRead(chat);
    if (wide) {
      setState(() => selected = chat);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: SafeArea(
              child: ChatPane(
                store: widget.store,
                chat: chat,
                onBack: () => Navigator.pop(context),
              ),
            ),
          ),
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotifyService.instance.onTap = _onNotifyTap;
    _initializeNotifications();
    // Real system ringing: wire the Telecom ConnectionService callbacks so
    // answer/decline/end from the system UI drive the full call flow.
    final callingClient = widget.client;
    if (callingClient != null) {
      unawaited(NativeCallService().initialize(callingClient));
      NativeCallService().onIncomingAccepted = _onIncomingAccepted;
      NativeCallService().onIncomingDeclined = _onIncomingDeclined;
    }
    widget.store.ensureSelfChat();
    _watchNotify();
    unawaited(_publishSignalKeys());
    
    // Initialize shared unread trackers for badge aggregation
    if (widget.client != null) {
      _directUnread = DirectUnread(widget.client!)..addListener(_onUnreadChanged);
      _directUnread!.start();
      _conversationRepo = ConversationRepository(
        widget.client!,
        secureHistory: widget.store.secureHistory,
      );
      _conversationRepo!.addListener(_onUnreadChanged);
      _conversationRepo!.subscribeToMembership();
      
      // Initialize badge service
      BadgeService.initialize(
        store: widget.store,
        repo: _conversationRepo!,
        directUnread: _directUnread!,
      );
    }
    
    // Load broadcast lists
    _broadcastService.load();
    // Silent scheduled backup (needs one manual backup first). Never
    // blocks startup and never surfaces errors.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoBackup());
    // WhatsApp-style address-book sync: silent refresh when permission is
    // already granted and the cache is stale. Never prompts on startup.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeAutoSyncContacts(),
    );
  }

  void _onUnreadChanged() {
    BadgeService.instance?.refresh();
  }

  Future<void> _publishSignalKeys() async {
    final client = widget.client;
    final accountId = client?.auth.currentUser?.id;
    if (client == null || accountId == null) return;
    try {
      await SignalCrypto(
        client: client,
        accountId: accountId,
        preferences: widget.store.preferences,
      ).ensureLocalKeysPublished();
    } catch (_) {
      // Chat/call flows retry key publication and surface their own errors.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeAutoBackup();
      unawaited(_resolveChatNames());
    }
  }

  /// Store-backed chat rows are created with a 'Loading...' placeholder
  /// until the peer's profile is resolved. Accepted contacts come from the
  /// contacts list; everyone else (e.g. someone who messaged first) is
  /// resolved straight from the profiles table. Guarded like the other
  /// build-side watchers: one network attempt per placeholder set.
  String? _nameResolveKey;
  DateTime _lastNameResolveAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  void _watchChatNames() {
    final uid = widget.client?.auth.currentUser?.id;
    if (uid == null) return;
    unawaited(_resolveChatNames());
  }

  Future<void> _resolveChatNames() async {
    final client = widget.client;
    final me = client?.auth.currentUser?.id;
    if (client == null || me == null) return;
    final missing = <String, String>{}; // peerId -> conversation id
    for (final c in widget.store.conversations) {
      if (c.name != 'Loading...' && c.name.trim().isNotEmpty) continue;
      final parsed = ChatStore.parseSecureConversationId(c.id);
      if (parsed == null || parsed.accountId != me) continue;
      if (parsed.peerId == me) continue; // self chat has its own title
      missing[parsed.peerId] = c.id;
    }
    if (missing.isEmpty) return;
    final key = missing.keys.toList()..sort();
    final signature = key.join(',');
    if (signature == _nameResolveKey &&
        DateTime.now().difference(_lastNameResolveAttempt) <
            const Duration(minutes: 1)) {
      return;
    }
    _nameResolveKey = signature;
    _lastNameResolveAttempt = DateTime.now();
    try {
      // The profiles table is RLS-restricted to its own row, so peer
      // display names must come from the contacts RPC — it serves every
      // invite status and joins the name server-side.
      final contacts = await SupabaseContactsRepository(client).contacts();
      for (final contact in contacts) {
        final id = missing[contact.userId];
        if (id == null) continue;
        final name = contact.name.trim();
        if (name.isNotEmpty) {
          await widget.store.renameConversation(id, name);
        }
      }
    } catch (_) {
      // Leave placeholders in place; a later store update or app resume
      // retries after the guard window.
    }
  }

  /// Silent contact refresh: runs at most once per day per account, only
  /// when the OS permission is already granted (no startup prompts).
  /// Results are cached for the People tab to show instantly.
  Future<void> _maybeAutoSyncContacts() async {
    final client = widget.client;
    final uid = client?.auth.currentUser?.id;
    if (uid == null) return;
    try {
      if (!await FlutterContacts.permissions.has(PermissionType.read)) return;
      final prefs = widget.store.preferences;
      final lastKey = 'openchat.sync.last.v1.$uid';
      final last = prefs.getInt(lastKey) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - last <
          const Duration(hours: 24).inMilliseconds) {
        return;
      }
      final result = await ContactSyncService(client!).syncFull();
      await prefs.setInt(lastKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.setString(
        'openchat.sync.matched.v1.$uid',
        jsonEncode([
          for (final m in result.matched)
            {
              'userId': m.contact.userId,
              'name': m.contact.name,
              'username': m.contact.username,
              'about': m.contact.about,
              'avatarUrl': m.contact.avatarUrl,
              'phone': m.phone,
            },
        ]),
      );
    } catch (_) {
      // Silent background refresh; the manual Sync button reports errors.
    }
  }

  Future<void> _maybeAutoBackup() async {
    final client = widget.client;
    final uid = client?.auth.currentUser?.id;
    if (uid == null) return;
    var backedUp = false;
    try {
      backedUp =
          await ChatBackup.maybeAutoBackup(
            client: client!,
            store: widget.store,
            uid: uid,
            prefs: widget.store.preferences,
          ) !=
          null;
    } catch (_) {}
    // WhatsApp-style: mirror the fresh encrypted snapshot to Drive on the
    // same schedule. Silent, Wi-Fi-aware, Drive-signed-in only.
    if (backedUp) {
      try {
        if (!await GoogleDriveBackup.isSignedIn()) return;
        if (!await GoogleDriveBackup.networkAllowed(
          widget.store.preferences,
          uid,
        )) {
          return;
        }
        final bytes = await ChatBackup.downloadBackup(client!, uid);
        if (bytes == null) return;
        await GoogleDriveBackup.uploadBackupBytes(
          bytes,
          GoogleDriveBackup.fileName(
            uid,
            DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
          ),
        );
        await GoogleDriveBackup.pruneOld(3);
      } catch (_) {}
    }
    // Cooperative expiry sweep for envelopes/receipts. Best-effort.
    try {
      await client!.rpc('cleanup_expired');
    } catch (_) {}
  }

  Future<void> _initializeNotifications() async {
    await NotifyService.instance.init();
    if (!mounted) return;
    await NotifyService.instance.ensurePermission();
    final tap = await NotifyService.instance.launchTap();
    if (tap != null && mounted) await _onNotifyTap(tap);
  }

  /// Foreground fan-in for message + status notifications. Never decrypts
  /// here: decoding anywhere but the open chat would fork the Signal
  /// ratchet, so message nudges carry the sender name only.
  void _watchNotify() {
    final client = widget.client;
    final uid = client?.auth.currentUser?.id;
    if (uid == null) {
      _notifyWatch?.unsubscribe();
      _notifyWatch = null;
      _notifyUid = null;
      return;
    }
    if (_notifyUid == uid && _notifyWatch != null) return;
    _notifyWatch?.unsubscribe();
    _notifyUid = uid;
    _refreshNotifyNames();
    _notifyWatch = client!.channel('notify:$uid')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'message_envelopes',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient_id',
          value: uid,
        ),
        callback: (payload) => _onNotifyMessage(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'status_updates',
        callback: (payload) => _onNotifyStatus(payload.newRecord),
      )
      ..subscribe();
  }

  Future<void> _refreshNotifyNames() async {
    final client = widget.client;
    if (client == null) return;
    try {
      final contacts = await SupabaseContactsRepository(client).contacts();
      _notifyNames = {
        for (final c in contacts.where((c) => c.status == 'accepted'))
          c.userId: c.name,
      };
    } catch (_) {}
  }

  Future<void> _onNotifyMessage(Map<String, dynamic> record) async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final uid = widget.client?.auth.currentUser?.id;
    final sender = record['sender_id'] as String? ?? '';
    if (uid == null ||
        !NotifyService.shouldNotifyMessage(
          myId: uid,
          senderId: sender,
          openPeers: NotifyService.instance.openChats,
        )) {
      return;
    }
    // Respect a per-chat mute: a muted conversation stays silent.
    if (widget.store.isPeerMuted(uid, sender)) return;
    // Per-chat tone: 'Silent' posts without sound or vibration.
    final tone =
        widget.store.preferences.getString('openchat.tone.v1.$uid.$sender') ??
        'Default';
    var name = _notifyNames[sender];
    if (name == null) {
      await _refreshNotifyNames();
      name = _notifyNames[sender] ?? 'New contact';
    }
    await NotifyService.instance.showMessage(
      peerId: sender,
      name: name,
      event: record['client_message_id'] as String?,
      silent: tone == 'Silent',
    );
  }

  Future<void> _onNotifyStatus(Map<String, dynamic> record) async {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final uid = widget.client?.auth.currentUser?.id;
    final author = record['author_id'] as String? ?? '';
    if (uid == null || author.isEmpty || author == uid) return;
    var name = _notifyNames[author];
    if (name == null) {
      await _refreshNotifyNames();
      name = _notifyNames[author];
    }
    // Only accepted contacts resolve to a name; strangers stay silent.
    if (name == null) return;
    final type = record['type'] as String? ?? 'text';
    final content = (record['content'] as String? ?? '').trim();
    await NotifyService.instance.showStatus(
      authorId: author,
      name: name,
      event: record['id'] as String?,
      snippet: type == 'text' && content.isNotEmpty
          ? (content.length > 80 ? '${content.substring(0, 80)}…' : content)
          : (type == 'image'
                ? 'Shared a photo status'
                : 'Shared a video status'),
    );
  }

  /// Notification tap routing: messages open the encrypted chat, groups open
  /// their thread, status jumps to the Status tab, and calls use the ringer.
  Future<void> _onNotifyTap(NotifyTap tap) async {
    if (!mounted) return;
    final client = widget.client;
    if (client == null) return;
    switch (tap.kind) {
      case 'msg':
        try {
          final contacts = await SupabaseContactsRepository(client).contacts();
          CloudContact? match;
          for (final c in contacts) {
            if (c.userId == tap.peer && c.status == 'accepted') {
              match = c;
              break;
            }
          }
          if (!mounted || match == null) return;
          setState(() => activeTab = 0);
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SecureChatScreen(
                profile: widget.profile,
                store: widget.store,
                push: widget.push,
                client: client,
                peerId: tap.peer,
                peerName: match!.name,
                peerUsername: match.username,
                peerAvatarUrl: match.avatarUrl,
                focusComposer: tap.action == 'reply',
              ),
            ),
          );
          return;
        } catch (_) {
          return;
        }
      case 'status':
        Navigator.of(context).popUntil((route) => route.isFirst);
        if (mounted) setState(() => activeTab = 2);
        return;
      case 'group':
        try {
          final group = await client
              .from('conversations')
              .select('id, title, avatar_url, e2ee_enabled')
              .eq('id', tap.peer)
              .inFilter('type', const ['group', 'channel'])
              .maybeSingle();
          if (!mounted || group == null) return;
          setState(() => activeTab = 0);
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => GroupChatScreen(
                conversationId: group['id'] as String,
                conversationTitle: group['title'] as String? ?? tap.name,
                avatarUrl: group['avatar_url'] as String?,
                secureHistory: widget.store.secureHistory,
                e2eeEnabled: group['e2ee_enabled'] == true,
              ),
            ),
          );
          return;
        } catch (_) {
          return;
        }
      case 'call':
        final invite = await client
            .from('call_invites')
            .select()
            .eq('id', tap.peer)
            .eq('callee_id', client.auth.currentUser?.id ?? '')
            .maybeSingle();
        if (!mounted) return;
        if (invite != null && invite['status'] == 'ringing') {
          await _onIncomingInvite(invite);
        } else {
          await NotifyService.instance.cancelCall(tap.peer);
          if (mounted) setState(() => activeTab = 3);
        }
        return;
      case 'missed_call':
        Navigator.of(context).popUntil((route) => route.isFirst);
        if (mounted) setState(() => activeTab = 3);
        return;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotifyService.instance.onTap = null;
    GroupVoiceChatService.instance.stop();
    _callWatch?.unsubscribe();
    _ringTimer?.cancel();
    unawaited(_ringWatch?.unsubscribe());
    _ringWatch = null;
    _ringSettle = null;
    NativeCallService().onIncomingAccepted = null;
    NativeCallService().onIncomingDeclined = null;
    NativeCallService().onCallUiEnded = null;
    _notifyWatch?.unsubscribe();
    _directUnread?.removeListener(_onUnreadChanged);
    _directUnread?.dispose();
    _conversationRepo?.removeListener(_onUnreadChanged);
    _conversationRepo?.unsubscribeFromMembership();
    _conversationRepo?.dispose();
    if (BadgeService.isInitialized) BadgeService.instance!.dispose();
    super.dispose();
  }

  /// Group voice rooms watcher: one realtime subscription for the signed-in
  /// user, driving the drop-in banners across all group chats.
  void _watchGroupVoice() {
    final client = widget.client;
    if (client == null) return;
    GroupVoiceChatService.instance.start(client);
  }

  /// Version gate: one fetch per signed-in uid, fail-open on any error.
  void _checkAppVersion() {
    final client = widget.client;
    final uid = client?.auth.currentUser?.id;
    if (client == null || uid == null) return;
    if (_versionCheckedForUid == uid) return;
    _versionCheckedForUid = uid;
    unawaited(_loadMinAppVersion(client));
  }

  Future<void> _loadMinAppVersion(SupabaseClient client) async {
    String? min;
    try {
      min = await fetchMinAppVersion(client);
    } catch (_) {
      return; // Unreachable gate: keep the app usable.
    }
    if (min == null) return;
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _minAppVersion = min;
        _installedAppVersion = info.version;
        _updateRequired = compareVersions(info.version, min!) < 0;
      });
    } catch (_) {}
  }

  Future<void> _recheckAppVersion() async {
    _versionCheckedForUid = null;
    _checkAppVersion();
  }

  /// Foreground incoming-call ringer. While signed in, watch our invite
  /// rows; an unanswered ring also needs the app open (background ringing
  /// arrives with push notifications).
  void _watchIncomingCalls(BuildContext context) {
    final client = widget.client;
    final uid = client?.auth.currentUser?.id;
    if (uid == null) {
      _callWatch?.unsubscribe();
      _callWatch = null;
      _callWatchUid = null;
      return;
    }
    if (_callWatchUid == uid && _callWatch != null) return;
    _callWatch?.unsubscribe();
    _callWatchUid = uid;
    _callWatch = client!.channel('calls:$uid')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'call_invites',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'callee_id',
          value: uid,
        ),
        callback: (payload) => _onIncomingInvite(payload.newRecord),
      )
      ..subscribe();
  }

  Future<void> _onIncomingInvite(Map<String, dynamic> record) async {
    if (!mounted || _incomingOpen) return;
    if (record['status'] != 'ringing') return;
    final created = DateTime.tryParse(record['created_at'] as String? ?? '');
    if (created != null &&
        DateTime.now().difference(created) > const Duration(seconds: 75)) {
      return;
    }
    final inviteId = record['id'] as String? ?? '';
    final callerId = record['caller_id'] as String? ?? '';
    final callType = record['call_type'] as String? ?? 'voice';
    if (inviteId.isEmpty || callerId.isEmpty) return;
    final client = widget.client!;
    String peerName = 'Unknown caller';
    try {
      final contacts = await SupabaseContactsRepository(client).contacts();
      for (final c in contacts) {
        if (c.userId == callerId) {
          peerName = c.name;
          break;
        }
      }
    } catch (_) {}
    if (!mounted || _incomingOpen) return;
    _incomingOpen = true;
    // Send delivery receipt so the caller knows the invite arrived.
    unawaited(CallSignaling.markDelivered(client, inviteId: inviteId));
    // Lock-screen / full-screen notification: rings even when the app is
    // swiped away or the device is locked (the Telecom ring below only
    // runs while this process is alive).
    await NotifyService.instance.showCall(
      inviteId: inviteId,
      name: peerName,
      video: callType == 'video',
    );
    if (!mounted) {
      _incomingOpen = false;
      return;
    }
    // Decrypt the end-to-end media key BEFORE ringing: the system call UI
    // needs it the moment the user answers, not after another round trip.
    final encryptedKey = record['encrypted_call_key'] as String?;
    String? mediaKey;
    if (encryptedKey != null && encryptedKey != 'legacy-disabled') {
      try {
        final decrypted = await SignalCrypto(
          client: client,
          accountId: client.auth.currentUser!.id,
          preferences: await SharedPreferences.getInstance(),
        ).decryptText(callerId, encryptedKey);
        if (base64Url.decode(base64Url.normalize(decrypted)).length == 32) {
          mediaKey = decrypted;
        }
      } catch (_) {
        // Ring anyway; a failed accept reports the error and declines.
      }
    }
    if (!mounted) {
      _incomingOpen = false;
      return;
    }
    // Real system ring: Telecom drives the ringtone, lock screen and
    // answer/decline buttons. Falls back to the in-app dialog when the
    // platform refuses (telecom unavailable, concurrent call, web/iOS).
    final native = NativeCallService();
    final rangNatively = await native.ringIncoming(
      inviteId: inviteId,
      peerId: callerId,
      peerName: peerName,
      video: callType == 'video',
      room: record['room'] as String?,
      mediaKey: mediaKey,
      client: client,
    );
    if (!mounted) {
      if (rangNatively) await native.reportCallEnded(inviteId);
      _incomingOpen = false;
      return;
    }
    if (rangNatively) {
      await _superviseNativeRing(
        client: client,
        inviteId: inviteId,
        callerId: callerId,
        peerName: peerName,
        callType: callType,
      );
      return;
    }
    await _showIncomingCallDialog(
      client: client,
      inviteId: inviteId,
      callerId: callerId,
      peerName: peerName,
      callType: callType,
      room: record['room'] as String? ?? '',
      encryptedCallKey: encryptedKey,
      created: created,
    );
  }
  /// Foreground fallback ring when Telecom is unavailable: the same accept
  /// flow as the system-UI path, presented as an in-app dialog.
  Future<void> _showIncomingCallDialog({
    required SupabaseClient client,
    required String inviteId,
    required String callerId,
    required String peerName,
    required String callType,
    required String room,
    String? encryptedCallKey,
    DateTime? created,
  }) async {
    var expired = false;
    final dialogNavigator = Navigator.of(context, rootNavigator: true);
    final dialogRoute = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Incoming ${callType == 'video' ? 'video' : 'voice'} call'),
        content: Text(peerName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Decline'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.call),
            label: const Text('Accept'),
          ),
        ],
      ),
    );
    // Expire this invite's route only. An old timer must never dismiss a
    // newer call, permission dialog, or unrelated page.
    final age = created == null
        ? Duration.zero
        : DateTime.now().difference(created);
    final remaining = const Duration(seconds: 60) - age;
    final expiry = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      expired = true;
      NotifyService.instance.cancelCall(inviteId);
      if (mounted && dialogRoute.isActive) {
        dialogNavigator.removeRoute(dialogRoute);
      }
    });
    bool? accept;
    try {
      accept = await dialogNavigator.push(dialogRoute);
    } finally {
      expiry.cancel();
      _incomingOpen = false;
      await NotifyService.instance.cancelCall(inviteId);
    }
    if (!mounted || expired) return;
    if (accept != true) {
      try {
        await CallSignaling.answer(client, inviteId: inviteId, accept: false);
        await CallRepository(client).add(
          peerLabel: peerName,
          peerId: callerId,
          callType: callType,
          outcome: 'declined',
          startedAt: DateTime.now(),
          durationSeconds: 0,
          direction: 'incoming',
        );
      } catch (_) {}
      return;
    }
    await _answerIncomingCall(
      client: client,
      inviteId: inviteId,
      callerId: callerId,
      peerName: peerName,
      callType: callType,
      room: room,
      encryptedCallKey: encryptedCallKey,
      service: CallService(),
      ownsService: true,
    );
  }

  /// Watches a natively ringing invite. When the caller gives up, tear the
  /// system ring down and log the miss. A local timer mirrors the server's
  /// 60-second timeout in case realtime is unreachable. The settle handle
  /// is shared with the accept/decline hooks so exactly one path cleans up.
  Future<void> _superviseNativeRing({
    required SupabaseClient client,
    required String inviteId,
    required String callerId,
    required String peerName,
    required String callType,
  }) async {
    var settled = false;
    Future<void> settle({required bool reportEnded, String? outcome}) async {
      if (settled) return;
      settled = true;
      _ringSettle = null;
      _ringTimer?.cancel();
      _ringTimer = null;
      try {
        await _ringWatch?.unsubscribe();
      } catch (_) {}
      _ringWatch = null;
      await NotifyService.instance.cancelCall(inviteId);
      if (reportEnded) await NativeCallService().reportCallEnded(inviteId);
      if (outcome == null || !mounted) return;
      try {
        await CallRepository(client).add(
          peerLabel: peerName,
          peerId: callerId,
          callType: callType,
          outcome: outcome,
          startedAt: DateTime.now(),
          durationSeconds: 0,
          direction: 'incoming',
        );
      } catch (_) {}
      if (mounted) setState(() {});
    }

    _ringSettle = () => settle(reportEnded: false);
    _ringTimer = Timer(
      const Duration(seconds: 60),
      () => settle(reportEnded: true, outcome: 'missed'),
    );
    _ringWatch = client.channel('ring:$inviteId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'call_invites',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: inviteId,
        ),
        callback: (payload) {
          final status = payload.newRecord['status'] as String?;
          if (status == 'ringing') return;
          // 'accepted'/'declined' mean this device already acted (or is
          // about to) — stop supervising without killing the connection.
          // 'ended' is the caller giving up: stop the ring, log the miss.
          settle(
            reportEnded: status != 'accepted' && status != 'declined',
            outcome: status == 'declined'
                ? 'declined'
                : (status == 'accepted' ? null : 'missed'),
          );
        },
      )
      ..subscribe();
  }

  /// System call UI accepted: stop supervising the ring and run the shared
  /// accept flow against NativeCallService's media session.
  Future<void> _onIncomingAccepted(CallInfo call) async {
    await _ringSettle?.call();
    final client = call.client ?? widget.client;
    if (client == null || !mounted) {
      await NativeCallService().reportCallEnded(call.uuid);
      return;
    }
    await _answerIncomingCall(
      client: client,
      inviteId: call.inviteId ?? call.uuid,
      callerId: call.handle,
      peerName: call.name,
      callType: call.video ? 'video' : 'voice',
      room: call.room ?? '',
      decryptedKey: call.mediaKey,
      service: NativeCallService().media,
      ownsService: false,
    );
  }

  /// System call UI declined: the decline RPC already went out from
  /// NativeCallService; just stop supervising. History logging comes from
  /// the invite status watcher.
  Future<void> _onIncomingDeclined(CallInfo call) async {
    await _ringSettle?.call();
  }

  /// Shared incoming-accept flow used by both the system call UI and the
  /// in-app dialog: verify the invite is still live, decrypt the media key
  /// (unless already decrypted), get permissions, exchange the LiveKit
  /// token, answer, join, present the call screen and log the outcome.
  Future<void> _answerIncomingCall({
    required SupabaseClient client,
    required String inviteId,
    required String callerId,
    required String peerName,
    required String callType,
    required String room,
    String? encryptedCallKey,
    String? decryptedKey,
    required CallService service,
    required bool ownsService,
  }) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // The ring may have died while the UI sat open: re-check before
    // answering so a stale Accept becomes "already ended", never raw SQL.
    try {
      final row = await client
          .from('call_invites')
          .select('status')
          .eq('id', inviteId)
          .maybeSingle();
      if (row == null || row['status'] != 'ringing') {
        messenger.showSnackBar(
          const SnackBar(content: Text('This call already ended.')),
        );
        await NativeCallService().reportCallEnded(inviteId);
        return;
      }
    } catch (_) {}
    late final String mediaKey;
    if (decryptedKey != null) {
      mediaKey = decryptedKey;
    } else {
      try {
        if (encryptedCallKey == null || encryptedCallKey == 'legacy-disabled') {
          throw StateError('This call does not contain an end-to-end key.');
        }
        mediaKey = await SignalCrypto(
          client: client,
          accountId: client.auth.currentUser!.id,
          preferences: await SharedPreferences.getInstance(),
        ).decryptText(callerId, encryptedCallKey);
        final keyBytes = base64Url.decode(base64Url.normalize(mediaKey));
        if (keyBytes.length != 32) {
          throw StateError('Invalid end-to-end call key.');
        }
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Secure call setup failed: $e')),
        );
        try {
          await CallSignaling.answer(client, inviteId: inviteId, accept: false);
        } catch (_) {}
        await NativeCallService().reportCallEnded(inviteId);
        return;
      }
    }
    if (!await service.ensurePermissions(video: callType == 'video')) {
      messenger.showSnackBar(
        SnackBar(content: Text(service.error ?? 'Permission denied.')),
      );
      try {
        await CallSignaling.answer(client, inviteId: inviteId, accept: false);
      } catch (_) {}
      await NativeCallService().reportCallEnded(inviteId);
      if (ownsService) service.dispose();
      return;
    }
    late final String url;
    late final String token;
    try {
      final creds = await CallSignaling.token(client, room: room, name: peerName);
      url = creds.url;
      token = creds.token;
      try {
        await CallSignaling.answer(client, inviteId: inviteId, accept: true);
      } catch (e) {
        // Lost race with the caller hanging up: report plainly.
        messenger.showSnackBar(
          const SnackBar(content: Text('This call already ended.')),
        );
        await NativeCallService().reportCallEnded(inviteId);
        if (ownsService) service.dispose();
        return;
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      await NativeCallService().reportCallEnded(inviteId);
      if (ownsService) service.dispose();
      return;
    }
    if (!await service.join(
      url: url,
      token: token,
      video: callType == 'video',
      mediaKey: mediaKey,
    )) {
      messenger.showSnackBar(
        SnackBar(content: Text(service.error ?? 'Could not join the call.')),
      );
      try {
        await CallSignaling.finish(client, inviteId: inviteId);
      } catch (_) {}
      await NativeCallService().reportCallEnded(inviteId);
      if (ownsService) service.dispose();
      return;
    }
    // The system call UI should flip from ringing to active.
    unawaited(NativeCallService().reportCallConnected(inviteId));
    final session = ActiveCallSession(
      callId: inviteId,
      peerUsername: peerName,
      peerDisplayName: peerName,
      type: callType == 'video' ? CallType.video : CallType.voice,
      initialState: CallState.connected,
    );
    final startedAt = DateTime.now();
    var incomingDone = false;
    RealtimeChannel? remoteWatch;
    // Set below; ending the call from the system UI (notification, headset,
    // telecom) must finish the app-side call too, not strand a dead screen.
    void Function(String)? uiEndListener;
    Future<void> finishIncoming(String outcome, {bool pop = true}) async {
      if (incomingDone) return;
      incomingDone = true;
      try {
        await remoteWatch?.unsubscribe();
      } catch (_) {}
      final native = NativeCallService();
      if (native.onCallUiEnded == uiEndListener) native.onCallUiEnded = null;
      if (outcome != 'remote') {
        try {
          await CallSignaling.finish(client, inviteId: inviteId);
        } catch (_) {}
      }
      await service.hangUp();
      try {
        await CallRepository(client).add(
          peerLabel: peerName,
          peerId: callerId,
          callType: callType,
          outcome: outcome == 'remote'
              ? (session.durationSeconds > 0 ? 'completed' : 'failed')
              : outcome,
          startedAt: startedAt,
          durationSeconds: session.durationSeconds,
          direction: 'incoming',
        );
      } catch (_) {}
      await NativeCallService().reportCallEnded(inviteId);
      if (ownsService) service.dispose();
      if (pop) {
        try {
          navigator.pop();
        } catch (_) {}
      }
    }

    void endFromSystemUi(String uuid) {
      if (uuid == inviteId) finishIncoming('remote');
    }

    uiEndListener = endFromSystemUi;
    NativeCallService().onCallUiEnded = endFromSystemUi;
    remoteWatch = client.channel('invite:$inviteId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'call_invites',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: inviteId,
        ),
        callback: (payload) {
          if (incomingDone) return;
          if (payload.newRecord['status'] == 'ended') {
            // Caller hung up: close our side too instead of stranding
            // this device on a dead call screen.
            finishIncoming('remote');
          }
        },
      )
      ..subscribe();
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => CallScreen(
          session: session,
          service: service,
          onEndCall: () => finishIncoming(
            session.durationSeconds > 0 ? 'completed' : 'failed',
          ),
        ),
      ),
    );
    await finishIncoming(
      session.durationSeconds > 0 ? 'completed' : 'failed',
      pop: false,
    );
  }

  /// WhatsApp-style: the new-chat button opens your real contacts, where
  /// tapping a contact opens the encrypted chat. No fictional conversations.
  Future<void> newChat(bool wide) async {
    final client = widget.client;
    if (client?.auth.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to start chatting.')),
      );
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ContactsPage(
          repository: SupabaseContactsRepository(client!),
          client: client,
          store: widget.store,
          push: widget.push,
          profile: widget.profile,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _createBroadcastList() async {
    // Open the broadcast lists page to create a new list
    // The page handles creation internally
    if (!mounted) return;
    // Navigate to broadcasts tab (already there) - FAB on broadcast page handles creation
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tap + in the Broadcasts tab to create a new list'),
      ),
    );
  }

  /// Group creation: name plus accepted contacts as initial members.
  Future<void> _createGroup() async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    List<CloudContact> accepted = [];
    try {
      accepted = (await SupabaseContactsRepository(
        client!,
      ).contacts()).where((c) => c.status == 'accepted').toList();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load contacts. Try again.')),
        );
      }
      return;
    }
    if (!mounted) return;
    final result = await showDialog<({String name, List<String> memberIds})>(
      context: context,
      builder: (_) => _NewGroupDialog(contacts: accepted),
    );
    if (result == null || !mounted) return;
    try {
      final repo = ConversationRepository(client);
      final id = await repo.createGroup(title: result.name);
      for (final memberId in result.memberIds) {
        try {
          await repo.addMember(id, memberId);
        } catch (_) {}
      }
      _groupsKey.currentState?.refresh();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => GroupChatScreen(
            conversationId: id,
            conversationTitle: result.name,
            secureHistory: widget.store.secureHistory,
            e2eeEnabled: true,
          ),
        ),
      );
      _groupsKey.currentState?.refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create group. ${cloudError(e)}')),
        );
      }
    }
  }

  /// WhatsApp-style long-press menu: pin, favourite, lock, archive, delete.
  Future<void> _chatActions(Conversation chat) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.mark_as_unread_sharp),
              title: Text(
                chat.unread > 0 || chat.markedUnread
                    ? 'Mark as read'
                    : 'Mark as unread',
              ),
              onTap: () => Navigator.pop(ctx, 'unread'),
            ),
            ListTile(
              leading: Icon(
                chat.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              title: Text(chat.pinned ? 'Unpin chat' : 'Pin to top'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            ListTile(
              leading: Icon(chat.favourite ? Icons.star : Icons.star_outline),
              title: Text(
                chat.favourite ? 'Remove from favourites' : 'Add to favourites',
              ),
              onTap: () => Navigator.pop(ctx, 'favourite'),
            ),
            ListTile(
              leading: Icon(
                chat.isMutedNow
                    ? Icons.volume_off_outlined
                    : Icons.notifications_outlined,
              ),
              title: Text(chat.isMutedNow ? 'Unmute' : 'Mute notifications'),
              subtitle: chat.isMutedNow
                  ? Text(
                      chat.mutedUntilMs == null
                          ? 'Muted always'
                          : 'Muted until ${DateTime.fromMillisecondsSinceEpoch(chat.mutedUntilMs!).toLocal().toString().split('.').first}',
                    )
                  : null,
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(chat.locked ? 'Unlock chat' : 'Lock chat'),
              subtitle: chat.locked
                  ? null
                  : const Text('Needs a chat lock PIN from Settings.'),
              onTap: () => Navigator.pop(ctx, 'lock'),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(chat.archived ? 'Unarchive' : 'Archive'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final store = widget.store;
    switch (action) {
      case 'unread':
        if (chat.unread > 0 || chat.markedUnread) {
          await store.markRead(chat);
          break;
        }
        await store.setMarkedUnread(chat.id, true);
      case 'pin':
        await store.setPinned(chat.id, !chat.pinned);
      case 'favourite':
        await store.setFavourite(chat.id, !chat.favourite);
      case 'mute':
        if (chat.isMutedNow) {
          await store.toggleMute(chat);
          break;
        }
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Mute notifications'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, '8h'),
                child: const Text('For 8 hours'),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, '1w'),
                child: const Text('For 1 week'),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'always'),
                child: const Text('Always'),
              ),
            ],
          ),
        );
        if (!mounted || choice == null) break;
        await store.setMute(chat, switch (choice) {
          '8h' => const Duration(hours: 8),
          '1w' => const Duration(days: 7),
          _ => null,
        });
      case 'lock':
        if (chat.locked) {
          await store.setLocked(chat.id, false);
        } else if (!await ChatLock.hasPin()) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Set a chat lock PIN in Settings first.'),
            ),
          );
        } else {
          await store.setLocked(chat.id, true);
          setState(() => lockRevealed = false);
        }
      case 'archive':
        await store.setArchived(chat.id, !chat.archived);
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete "${chat.name}"?'),
            content: const Text(
              'This removes the conversation from this device forever. Encrypted cloud chats are unaffected.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await store.deleteConversation(chat.id);
          // The personal thread is infrastructure, not data: it returns
          // empty rather than staying deleted.
          if (chat.id == ChatStore.selfChatId) {
            await store.ensureSelfChat();
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        _checkAppVersion();
        if (_updateRequired) {
          return AppUpdateGate(
            currentVersion: _installedAppVersion ?? '?',
            minVersion: _minAppVersion ?? '?',
            onRecheck: _recheckAppVersion,
          );
        }
        _watchIncomingCalls(context);
        _watchNotify();
        _watchGroupVoice();
        _watchChatNames();
        final wide = constraints.maxWidth >= 850;
        // Short screens (landscape phones, large text): shrink the fixed
        // header so the conversation list keeps room instead of overflowing.
        final compact = constraints.maxHeight < 520;
        final base = widget.store.conversations.where((c) {
          if (!c.name.toLowerCase().contains(query.toLowerCase())) {
            return false;
          }
          if (c.archived) return false;
          if (filter == 'unread' && c.unread == 0 && !c.markedUnread) {
            return false;
          }
          if (filter == 'favourites' && !c.favourite) return false;
          if (filter == 'groups') return false;
          if (c.locked && !lockRevealed) return false;
          return true;
        }).toList();
        // Pinned chats stay first; every other conversation is ordered by its
        // newest message so a newly received reply immediately rises to top.
        final indexed = base.asMap().entries.toList();
        indexed.sort((a, b) {
          if (a.value.pinned != b.value.pinned) {
            return a.value.pinned ? -1 : 1;
          }
          final aAt = a.value.messages.isEmpty
              ? DateTime.fromMillisecondsSinceEpoch(0)
              : a.value.messages.last.at;
          final bAt = b.value.messages.isEmpty
              ? DateTime.fromMillisecondsSinceEpoch(0)
              : b.value.messages.last.at;
          final recency = bAt.compareTo(aAt);
          return recency == 0 ? a.key.compareTo(b.key) : recency;
        });
        final chats = [for (final e in indexed) e.value];
        final lockedCount = widget.store.conversations
            .where((c) => c.locked && !c.archived)
            .length;
        final archivedChats = widget.store.conversations
            .where(
              (c) =>
                  c.archived &&
                  c.name.toLowerCase().contains(query.toLowerCase()),
            )
            .toList();
        // Single scroll container: on short screens (landscape, large
        // text) the fixed header plus secure/archived sections can exceed
        // the viewport, so everything scrolls instead of overflowing.
        final list = SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  compact ? 8 : 24,
                  16,
                  compact ? 4 : 12,
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ProfilePage(
                            profile: widget.profile,
                            client: widget.client,
                          ),
                        ),
                      ),
                      child: Semantics(
                        label: 'Your profile photo',
                        image: true,
                        child: ListenableBuilder(
                          listenable: widget.profile,
                          builder: (context, _) {
                            final file = widget.profile.avatarFile;
                            if (file != null) {
                              return CircleAvatar(
                                radius: 18,
                                foregroundImage: FileImage(file),
                              );
                            }
                            return Image.asset(
                              Theme.of(context).brightness == Brightness.dark
                                  ? 'assets/logos/openchat_dove_white.png'
                                  : 'assets/logos/openchat_dove.png',
                              width: 30,
                              height: 30,
                              fit: BoxFit.contain,
                            );
                          },
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Camera — new status',
                      icon: const Icon(Icons.photo_camera_outlined),
                      onPressed: () => setState(() => activeTab = 2),
                    ),
                    IconButton(
                      tooltip: 'My profile',
                      icon: const Icon(Icons.account_circle_outlined),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ProfilePage(
                            profile: widget.profile,
                            client: widget.client,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => setState(() => activeTab = 4),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'More options',
                      icon: const Icon(Icons.more_vert),
                      onSelected: (value) {
                        switch (value) {
                          case 'profile':
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => ProfilePage(
                                  profile: widget.profile,
                                  client: widget.client,
                                ),
                              ),
                            );
                          case 'new':
                            newChat(wide);
                          case 'group':
                            _createGroup();
                          case 'features':
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => FeatureHubPage(
                                  preferences: ChatPreferences(
                                    widget.store.preferences,
                                  ),
                                ),
                              ),
                            );
                          case 'settings':
                            setState(() => activeTab = 4);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'profile',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.account_circle_outlined),
                            title: Text('My profile'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'new',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.edit_square),
                            title: Text('New conversation'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'group',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.group_add_outlined),
                            title: Text('New group'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'features',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.auto_awesome_outlined),
                            title: Text('OpenChat features'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'settings',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.settings_outlined),
                            title: Text('Settings'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'A little closer, wherever you are.',
                  style: TextStyle(color: Color(0xFF66748A)),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(compact ? 12 : 24),
                child: TextField(
                  onChanged: (v) => setState(() => query = v),
                  decoration: const InputDecoration(
                    hintText: 'Search conversations',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ChoiceChip(
                              label: const Text('All chats'),
                              selected: filter == 'all',
                              onSelected: (_) => setState(() => filter = 'all'),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Unread'),
                              selected: filter == 'unread',
                              onSelected: (_) =>
                                  setState(() => filter = 'unread'),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Favourites'),
                              selected: filter == 'favourites',
                              onSelected: (_) =>
                                  setState(() => filter = 'favourites'),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Groups'),
                              selected: filter == 'groups',
                              onSelected: (_) =>
                                  setState(() => filter = 'groups'),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              avatar: const Icon(
                                Icons.archive_outlined,
                                size: 18,
                              ),
                              label: const Text('Archived'),
                              selected: archivedOpen,
                              onSelected: (_) =>
                                  setState(() => archivedOpen = !archivedOpen),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'New conversation',
                      onPressed: () => newChat(wide),
                      icon: const Icon(Icons.edit_square),
                    ),
                  ],
                ),
              ),
              SizedBox(height: compact ? 6 : 16),
              if (widget.client?.auth.currentUser != null && filter != 'groups')
                _SecureSection(
                  key: ValueKey(widget.client!.auth.currentUser!.id),
                  client: widget.client!,
                  store: widget.store,
                  profile: widget.profile,
                  push: widget.push,
                  query: query,
                  unreadOnly: filter == 'unread',
                  directUnread: _directUnread,
                ),
              if (widget.client?.auth.currentUser != null)
                _GroupSection(
                  key: _groupsKey,
                  client: widget.client!,
                  secureHistory: widget.store.secureHistory,
                  onCreateGroup: _createGroup,
                  query: query,
                  filter: filter,
                  conversationRepo: _conversationRepo,
                ),
              if (lockedCount > 0)
                FutureBuilder<String?>(
                  future: ChatLock.secretCode(),
                  builder: (context, snapshot) {
                    final secret = (snapshot.data ?? '').trim();
                    // Secret-code mode: hide folder unless query matches code
                    // or chats already revealed via PIN.
                    if (secret.isNotEmpty &&
                        !lockRevealed &&
                        query.trim() != secret) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const CircleAvatar(
                          child: Icon(Icons.lock_outline, size: 20),
                        ),
                        title: Text(
                          lockRevealed
                              ? 'Hide locked chats'
                              : 'Locked chats ($lockedCount)',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: lockRevealed
                            ? null
                            : Text(
                                secret.isEmpty
                                    ? 'Verify your PIN to reveal them.'
                                    : 'Type secret code in search or verify PIN.',
                              ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          if (lockRevealed) {
                            setState(() => lockRevealed = false);
                            return;
                          }
                          if (await ChatLock.promptVerify(context)) {
                            if (!mounted) return;
                            setState(() => lockRevealed = true);
                          }
                        },
                      ),
                    );
                  },
                ),
              if (archivedChats.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const CircleAvatar(
                          child: Icon(Icons.archive_outlined, size: 20),
                        ),
                        title: Text(
                          'Archived (${archivedChats.length})',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        trailing: AnimatedRotation(
                          turns: archivedOpen ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(Icons.expand_more),
                        ),
                        onTap: () =>
                            setState(() => archivedOpen = !archivedOpen),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 250),
                        alignment: Alignment.topCenter,
                        child: archivedOpen
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (final c in archivedChats)
                                    ListTile(
                                      contentPadding: const EdgeInsets.only(
                                        left: 12,
                                      ),
                                      leading: ContactAvatar(chat: c),
                                      title: Text(
                                        c.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        c.messages.isEmpty
                                            ? 'No messages'
                                            : securePreviewFor(
                                                c.messages.last.text,
                                                mine: c.messages.last.mine,
                                              ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: IconButton(
                                        tooltip: 'Unarchive',
                                        icon: const Icon(
                                          Icons.unarchive_outlined,
                                        ),
                                        onPressed: () => widget.store
                                            .setArchived(c.id, false),
                                      ),
                                      onTap: () => open(c, wide),
                                      onLongPress: () => _chatActions(c),
                                    ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              chats.isEmpty && filter != 'groups'
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Text(
                          'No conversations found.\nStart a chat with the compose button.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: chats.length,
                      itemBuilder: (context, i) {
                        final chat = chats[i];
                        return AppearOnce(
                          key: ValueKey('chat-${chat.id}'),
                          child: Dismissible(
                            key: ValueKey(chat.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 24),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Icon(
                                Icons.archive_outlined,
                                color: Colors.white,
                              ),
                            ),
                            onDismissed: (_) async {
                              await widget.store.setArchived(chat.id, true);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('${chat.name} archived.'),
                                    action: SnackBarAction(
                                      label: 'Undo',
                                      onPressed: () => widget.store.setArchived(
                                        chat.id,
                                        false,
                                      ),
                                    ),
                                  ),
                                );
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 3,
                              ),
                              child: Material(
                                color: selected == chat && wide
                                    ? const Color(0xFFE8EEFD)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(18),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.all(12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  leading: ContactAvatar(chat: chat),
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          chat.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      if (chat.pinned)
                                        const Padding(
                                          padding: EdgeInsets.only(left: 4),
                                          child: Icon(
                                            Icons.push_pin_outlined,
                                            size: 14,
                                            color: Color(0xFF66748A),
                                          ),
                                        ),
                                      if (chat.favourite)
                                        const Padding(
                                          padding: EdgeInsets.only(left: 4),
                                          child: Icon(
                                            Icons.star,
                                            size: 14,
                                            color: Color(0xFFF59E0B),
                                          ),
                                        ),
                                      if (chat.locked)
                                        const Padding(
                                          padding: EdgeInsets.only(left: 4),
                                          child: Icon(
                                            Icons.lock_outline,
                                            size: 14,
                                            color: Color(0xFF66748A),
                                          ),
                                        ),
                                    ],
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text(
                                      chat.messages.isEmpty
                                          ? 'Say hello'
                                          : securePreviewFor(
                                              chat.messages.last.text,
                                              mine: chat.messages.last.mine,
                                            ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        chat.messages.isEmpty
                                            ? ''
                                            : timeLabel(chat.messages.last.at),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF66748A),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      if (chat.isMutedNow)
                                        const Padding(
                                          padding: EdgeInsets.only(bottom: 4),
                                          child: Icon(
                                            Icons.volume_off,
                                            size: 14,
                                            color: Color(0xFF66748A),
                                          ),
                                        ),
                                      if (chat.unread > 0)
                                        CircleAvatar(
                                          radius: 10,
                                          backgroundColor: const Color(
                                            0xFF245CDB,
                                          ),
                                          child: Text(
                                            '${chat.unread}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.white,
                                            ),
                                          ),
                                        )
                                      else if (chat.markedUnread)
                                        const Padding(
                                          padding: EdgeInsets.only(right: 4),
                                          child: Icon(
                                            Icons.fiber_manual_record,
                                            size: 12,
                                            color: Color(0xFF245CDB),
                                          ),
                                        ),
                                    ],
                                  ),
                                  onTap: () => open(chat, wide),
                                  onLongPress: () => _chatActions(chat),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
              if (widget.store.storageWarning != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    widget.store.storageWarning!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        );
        final currentBody = switch (activeTab) {
          1 => BroadcastListsPage(
            service: _broadcastService,
            client: widget.client,
            store: widget.store,
            profile: widget.profile,
            push: widget.push,
          ),
          2 => StatusPage(client: widget.client, profile: widget.profile),
          3 => CallHistoryPage(client: widget.client, onNewCall: () => newChat(false)),
          4 => SettingsPage(
            store: widget.store,
            profile: widget.profile,
            push: widget.push,
            client: widget.client,
            startupError: widget.startupError,
            theme: widget.theme,
          ),
          _ => list,
        };

        return Scaffold(
          body: SafeArea(
            child: wide && activeTab == 0
                ? Row(
                    children: [
                      SizedBox(width: 370, child: list),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child:
                            selected != null &&
                                widget.store.conversations.contains(selected)
                            ? ChatPane(
                                key: ValueKey(selected!.id),
                                store: widget.store,
                                chat: selected!,
                              )
                            : const _Welcome(),
                      ),
                    ],
                  )
                : currentBody,
          ),
          floatingActionButton: (activeTab == 0 || activeTab == 1)
              ? FloatingActionButton(
                  tooltip: activeTab == 0 ? 'New chat' : 'New broadcast',
                  onPressed: activeTab == 0
                      ? () => newChat(wide)
                      : () => _createBroadcastList(),
                  child: Icon(
                    activeTab == 0
                        ? Icons.chat_outlined
                        : Icons.campaign_outlined,
                  ),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: activeTab,
            onDestinationSelected: (index) {
              setState(() => activeTab = index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_outlined),
                selectedIcon: Icon(Icons.chat),
                label: 'Chats',
              ),
              NavigationDestination(
                icon: Icon(Icons.campaign_outlined),
                selectedIcon: Icon(Icons.campaign),
                label: 'Broadcasts',
              ),
              NavigationDestination(
                icon: Icon(Icons.donut_large_outlined),
                selectedIcon: Icon(Icons.donut_large),
                label: 'Status',
              ),
              NavigationDestination(
                icon: Icon(Icons.call_outlined),
                selectedIcon: Icon(Icons.call),
                label: 'Calls',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        );
      },
    ),
  );
}

class ContactAvatar extends StatelessWidget {
  const ContactAvatar({super.key, required this.chat});
  final Conversation chat;
  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 25,
    backgroundColor: Color(chat.color),
    child: Text(
      chat.initials,
      style: const TextStyle(
        color: Color(0xFF23344F),
        fontWeight: FontWeight.w700,
        fontSize: 16,
      ),
    ),
  );
}

String timeLabel(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

/// WhatsApp-style one-line preview for an encrypted message body: text
/// snippet or media/poll glyph. Raw stored bodies are JSON envelopes, so
/// chat-list tiles must never render them directly.
String securePreviewFor(String raw, {bool mine = false}) {
  final body = parseMessageBody(raw);
  final String preview;
  if (body.isImage) {
    preview = '📷 ${body.text.isEmpty ? 'Photo' : body.text}';
  } else if (body.isVideo) {
    preview = '🎬 ${body.text.isEmpty ? 'Video' : body.text}';
  } else if (body.isPoll) {
    preview = '📊 ${body.question ?? 'Poll'}';
  } else if (body.isVote) {
    preview = '🗳️ Voted in a poll';
  } else if (body.isTombstone) {
    preview = 'This message was deleted';
  } else if (body.isReply) {
    preview = body.text;
  } else if (body.text.length > 60) {
    preview = '${body.text.substring(0, 60)}…';
  } else {
    preview = body.text;
  }
  return mine ? 'You: $preview' : preview;
}

/// Cloud-backed encrypted conversations for accepted contacts. Visible only
/// when signed in; the local demo list below stays for everyone.
class _SecureSection extends StatefulWidget {
  const _SecureSection({
    super.key,
    required this.client,
    required this.store,
    required this.profile,
    required this.push,
    this.query = '',
    this.unreadOnly = false,
    this.directUnread,
  });
  final SupabaseClient client;
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  final String query;
  final bool unreadOnly;
  final DirectUnread? directUnread;
  @override
  State<_SecureSection> createState() => _SecureSectionState();
}

class _SecureRow {
  const _SecureRow({
    required this.contact,
    required this.preview,
    this.at,
    this.unread = false,
    this.hasDraft = false,
    this.isSelf = false,
  });
  final CloudContact contact;
  final String preview;
  final DateTime? at;
  final bool unread;
  final bool hasDraft;

  /// True for the pinned "Message yourself" row.
  final bool isSelf;
}

class _SecureSectionState extends State<_SecureSection> {
  late Future<List<_SecureRow>> _future;
  late final DirectUnread _unread;
  /// Signed-in user's own cloud profile: powers the pinned
  /// "Message yourself" row (WhatsApp-style self chat) in real time.
  AccountProfile? _ownProfile;

  @override
  void initState() {
    super.initState();
    _unread = widget.directUnread!;
    _unread.addListener(_localChanged);
    widget.store.addListener(_localChanged);
    // Real-time profile changes (avatar/name/online) refresh this section.
    ProfileWatcher.of(widget.client).start();
    ProfileWatcher.of(widget.client).addListener(_profilesChanged);
    unawaited(_loadOwnProfile());
    _future = _load();
  }

  Future<void> _loadOwnProfile() async {
    try {
      final own = await SupabaseContactsRepository(
        widget.client,
      ).profile();
      if (mounted) setState(() => _ownProfile = own);
    } catch (e) {
      ErrorReport.reportError('selfchat-profile', e, code: 'load');
    }
  }

  void _profilesChanged() {
    if (!mounted) return;
    setState(() => _future = _load());
    unawaited(_loadOwnProfile());
  }

  void _localChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.removeListener(_localChanged);
    _unread.removeListener(_localChanged);
    ProfileWatcher.of(widget.client).removeListener(_profilesChanged);
    super.dispose();
  }

  Future<List<_SecureRow>> _load() async {
    final me = widget.client.auth.currentUser?.id;
    final contacts = (await SupabaseContactsRepository(
      widget.client,
    ).contacts()).where((c) => c.status == 'accepted').toList();
    final rows = [for (final c in contacts) _row(me, c)];
    rows.sort((a, b) {
      final aAt = a.at ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bAt = b.at ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bAt.compareTo(aAt);
    });
    return rows;
  }

  /// The pinned "Message yourself" row: a real encrypted self chat backed
  /// by the durable sealed-history store (peer id == own account id).
  _SecureRow _selfRow(String? me, AccountProfile own) {
    if (me == null) {
      return _SecureRow(
        contact: CloudContact(
          userId: '',
          name: 'Message yourself',
          username: own.username ?? '',
          about: null,
          avatarUrl: own.avatarUrl,
          avatarPath: own.avatarPath,
          status: 'accepted',
          incoming: false,
        ),
        preview: 'Sign in to sync your notes.',
        isSelf: true,
      );
    }
    final msgs = widget.store.getSecureConversation(me, me);
    String preview = 'Your personal notes, synced to your backup.';
    DateTime? at;
    var unread = false;
    if (msgs.isNotEmpty) {
      final last = msgs.last;
      preview = securePreviewFor(last.text, mine: last.mine);
      at = last.at;
      unread = widget.store.secureUnread(me, me);
    }
    return _SecureRow(
      contact: CloudContact(
        userId: me,
        name: 'Message yourself',
        username: own.username ?? '',
        about: null,
        avatarUrl: own.avatarUrl,
        avatarPath: own.avatarPath,
        status: 'accepted',
        incoming: false,
      ),
      preview: preview,
      at: at,
      unread: unread,
      isSelf: true,
    );
  }

  /// Last-message preview so encrypted chats feel persistent: text
  /// snippet, media/poll glyphs, or the invite hint when empty.
  _SecureRow _row(String? me, CloudContact contact) {
    final fallback = '@${contact.username} • end-to-end encrypted';
    if (me == null) {
      return _SecureRow(contact: contact, preview: fallback);
    }
    final msgs = widget.store.getSecureConversation(me, contact.userId);
    final unread =
        widget.store.secureUnread(me, contact.userId) ||
        (_unread.counts[contact.userId] ?? 0) > 0;
    if (msgs.isEmpty) {
      return _SecureRow(
        contact: contact,
        preview: unread ? 'New encrypted message' : fallback,
        unread: unread,
      );
    }
    final last = msgs.last;
    final preview = securePreviewFor(last.text, mine: last.mine);
    final draft = widget.store.secureDraft(me, contact.userId);
    return _SecureRow(
      contact: contact,
      preview: draft.isNotEmpty ? '✏️ Draft: $draft' : preview,
      at: last.at,
      unread: unread,
      hasDraft: draft.isNotEmpty,
    );
  }

  void _refresh() {
    if (!mounted) return;
    unawaited(_unread.refresh());
    setState(() => _future = _load());
  }

  Future<void> _rowActions(_SecureRow row) async {
    final me = widget.client.auth.currentUser?.id;
    if (me == null) return;
    final unread = row.unread;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                unread
                    ? Icons.mark_chat_read_outlined
                    : Icons.mark_chat_unread_outlined,
              ),
              title: Text(unread ? 'Mark as read' : 'Mark as unread'),
              onTap: () => Navigator.pop(ctx, 'read'),
            ),
          ],
        ),
      ),
    );
    if (action == 'read') {
      if (unread && (_unread.counts[row.contact.userId] ?? 0) > 0) {
        // Reading encrypted pending messages requires opening/unlocking them.
        if (mounted) _open(row.contact);
        return;
      }
      await widget.store.setSecureUnread(me, row.contact.userId, !unread);
      _refresh();
    }
  }

  void _open(CloudContact contact) {
    final me = widget.client.auth.currentUser?.id;
    if (me != null) {
      widget.store.setSecureUnread(me, contact.userId, false);
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SecureChatScreen(
          profile: widget.profile,
          store: widget.store,
          push: widget.push,
          client: widget.client,
          peerId: contact.userId,
          peerName: contact.name,
          peerUsername: contact.username,
          peerAvatarUrl: contact.avatarUrl,
        ),
      ),
    ).then((_) => _refresh());
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.lock_outline, size: 16, color: Color(0xFF245CDB)),
            const SizedBox(width: 6),
            const Text(
              'Encrypted chats',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh encrypted chats',
              visualDensity: VisualDensity.compact,
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
        FutureBuilder<List<_SecureRow>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Could not load encrypted chats. Pull to retry with the refresh button.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF66748A),
                  ),
                ),
              );
            }
            final loaded = snapshot.data ?? const <_SecureRow>[];
            // Rebuild previews and ordering from durable local history on
            // every store update so incoming messages move their chat to top
            // without waiting for a manual refresh.
            final search = widget.query.trim().toLowerCase();
            final selfRow = _ownProfile == null
                ? null
                : _selfRow(widget.client.auth.currentUser?.id, _ownProfile!);
            final chats =
                [
                      if (selfRow != null) selfRow,
                      for (final row in loaded)
                        _row(widget.client.auth.currentUser?.id, row.contact),
                    ]
                    .where(
                      (row) =>
                          (!widget.unreadOnly || row.unread) &&
                          (search.isEmpty ||
                              '${row.contact.name} ${row.contact.username} ${row.preview}'
                                  .toLowerCase()
                                  .contains(search)),
                    )
                    .toList()
                  ..sort((a, b) {
                    // The self chat stays pinned to the very top, like
                    // WhatsApp's "Message yourself".
                    if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
                    final aAt = a.at ?? DateTime.fromMillisecondsSinceEpoch(0);
                    final bAt = b.at ?? DateTime.fromMillisecondsSinceEpoch(0);
                    return bAt.compareTo(aAt);
                  });
            if (chats.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  loaded.isEmpty
                      ? 'No encrypted chats yet. Add someone in Settings → People & profile, then open their encrypted chat here.'
                      : 'No encrypted chats match this filter.',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF66748A)),
                ),
              );
            }
            // Shrink-wrapped (never a fixed height): rows can grow with
            // large fonts or long previews without overflowing.
            return ListenableBuilder(
              listenable: widget.store,
              builder: (context, _) => ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: chats.length,
                itemBuilder: (context, i) {
                  final row = chats[i];
                  final contact = row.contact;
                  return AppearOnce(
                    key: ValueKey('secure-${contact.userId}'),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFE4EBFF),
                        foregroundImage:
                            (contact.avatarUrl != null &&
                                contact.avatarUrl!.isNotEmpty)
                            ? NetworkImage(contact.avatarUrl!)
                            : null,
                        child: Text(
                          contact.name.isEmpty
                              ? '?'
                              : contact.name[0].toUpperCase(),
                          style: const TextStyle(
                            color: Color(0xFF245CDB),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      title: Text(
                        contact.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        row.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: row.hasDraft ? const Color(0xFF245CDB) : null,
                        ),
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (row.at != null)
                            Text(
                              timeLabel(row.at!),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF66748A),
                              ),
                            ),
                          if (row.unread)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Color(0xFF245CDB),
                                shape: BoxShape.circle,
                              ),
                            )
                          else
                            const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () => _open(contact),
                      onLongPress: () => _rowActions(row),
                    ),
                  );
                },
              ),
            );
          },
        ),
        const Divider(height: 16),
      ],
    ),
  );
}

/// Cloud group threads for accepted contacts. Visible only when signed
/// in; groups are transport-secured via RLS, not end-to-end encrypted.
class _GroupSection extends StatefulWidget {
  const _GroupSection({
    super.key,
    required this.client,
    required this.secureHistory,
    required this.onCreateGroup,
    this.query = '',
    this.filter = 'all',
    this.conversationRepo,
  });
  final SupabaseClient client;
  final SecureHistoryDatabase? secureHistory;
  final VoidCallback onCreateGroup;
  final String query;
  final String filter;
  final ConversationRepository? conversationRepo;
  @override
  State<_GroupSection> createState() => _GroupSectionState();
}

class _GroupSectionState extends State<_GroupSection> {
  late final ConversationRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = widget.conversationRepo!;
    _repo.addListener(_changed);
    refresh();
    _repo.subscribeToMembership();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> refresh() => _repo.loadConversations();

  /// WhatsApp-style long-press menu for group/channel rows.
  Future<void> _groupActions(GroupConversation group) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                group.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              title: Text(group.isPinned ? 'Unpin chat' : 'Pin to top'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            ListTile(
              leading: Icon(
                group.isFavourite ? Icons.star : Icons.star_outline,
              ),
              title: Text(
                group.isFavourite
                    ? 'Remove from favourites'
                    : 'Add to favourites',
              ),
              onTap: () => Navigator.pop(ctx, 'favourite'),
            ),
            ListTile(
              leading: Icon(
                group.isMuted ? Icons.notifications_off : Icons.notifications,
              ),
              title: Text(
                group.isMuted ? 'Unmute notifications' : 'Mute notifications',
              ),
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
            ListTile(
              leading: Icon(
                group.isArchived ? Icons.unarchive : Icons.archive_outlined,
              ),
              title: Text(group.isArchived ? 'Unarchive' : 'Archive'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              leading: Icon(
                group.isLocked ? Icons.lock_open : Icons.lock_outline,
              ),
              title: Text(group.isLocked ? 'Unlock chat' : 'Lock chat'),
              onTap: () => Navigator.pop(ctx, 'lock'),
            ),
            ListTile(
              leading: Icon(
                group.markedUnread || group.unreadCount > 0
                    ? Icons.mark_chat_read_outlined
                    : Icons.mark_chat_unread_outlined,
              ),
              title: Text(
                group.markedUnread || group.unreadCount > 0
                    ? 'Mark as read'
                    : 'Mark as unread',
              ),
              onTap: () => Navigator.pop(ctx, 'unread'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'pin':
        await _repo.setConversationFlags(group.id, pinned: !group.isPinned);
        return;
      case 'favourite':
        await _repo.setConversationFlags(
          group.id,
          favourite: !group.isFavourite,
        );
        return;
      case 'mute':
        if (group.isMuted) {
          await _repo.setConversationFlags(group.id, muted: false);
        } else {
          final choice = await _pickMuteDuration();
          if (choice.cancelled) return;
          await _repo.setConversationFlags(
            group.id,
            muted: true,
            mutedUntil: choice.until,
          );
        }
        return;
      case 'archive':
        await _repo.setConversationFlags(group.id, archived: !group.isArchived);
        return;
      case 'lock':
        await _repo.setConversationFlags(group.id, locked: !group.isLocked);
        return;
      case 'unread':
        final hasUnread = group.markedUnread || group.unreadCount > 0;
        if (hasUnread) {
          await _repo.markGroupRead(
            group.id,
            group.lastActivity ?? DateTime.now().toUtc(),
          );
        }
        await _repo.setConversationFlags(group.id, markedUnread: !hasUnread);
        return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Chat updated.')));
  }

  /// Returns the mute expiry and whether the picker was cancelled.
  Future<({bool cancelled, DateTime? until})> _pickMuteDuration() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in const [
              ('8 hours', 8),
              ('1 week', 24 * 7),
              ('Always', 0),
            ])
              ListTile(
                title: Text('Mute for ${option.$1}'),
                onTap: () => Navigator.pop(ctx, '${option.$2}'),
              ),
          ],
        ),
      ),
    );
    if (value == null) return (cancelled: true, until: null);
    final hours = int.parse(value);
    if (hours == 0) return (cancelled: false, until: null);
    return (
      cancelled: false,
      until: DateTime.now().add(Duration(hours: hours)),
    );
  }

  @override
  void dispose() {
    _repo.removeListener(_changed);
    _repo.unsubscribeFromMembership();
    // Don't dispose _repo - it's shared and managed by _ChatHomeState
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.query.trim().toLowerCase();
    final matches = _repo.conversations
        .where((c) => c.isGroup || c.isChannel)
        .where(
          (c) =>
              q.isEmpty ||
              (c.title ?? '').toLowerCase().contains(q) ||
              (c.lastMessage ?? '').toLowerCase().contains(q),
        );
    final filter = widget.filter;
    // Archived groups leave the main list (they surface in the Archive view);
    // the "groups" filter explicitly lists archives too.
    final groups = matches.where((c) {
      if (filter == 'groups') return true;
      if (c.isArchived) return false;
      if (filter == 'unread' && c.unreadCount == 0 && !c.markedUnread) {
        return false;
      }
      if (filter == 'favourites' && !c.isFavourite) return false;
      return true;
    }).toList();
    if (_repo.loading && groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    if (_repo.error != null && groups.isEmpty) {
      return const SizedBox.shrink();
    }
    if (groups.isEmpty) return const SizedBox.shrink();
    final sectionTitle = filter == 'favourites' ? 'Favourite groups' : 'Groups';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 8, 0),
          child: Row(
            children: [
              const Icon(Icons.group_outlined, size: 18),
              const SizedBox(width: 8),
              Text(
                sectionTitle,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'New group',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onCreateGroup,
                icon: const Icon(Icons.group_add_outlined, size: 18),
              ),
              IconButton(
                tooltip: 'Refresh groups',
                visualDensity: VisualDensity.compact,
                onPressed: refresh,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        for (final group in groups)
          AppearOnce(
            key: ValueKey('group-${group.id}'),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: const Color(0xFFE4EBFF),
                foregroundImage:
                    (group.avatarUrl != null && group.avatarUrl!.isNotEmpty)
                    ? NetworkImage(group.avatarUrl!)
                    : null,
                child: Text(
                  ((group.title ?? '').trim().isEmpty)
                      ? '?'
                      : group.title!.trim()[0].toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFF245CDB),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      (group.title?.trim().isNotEmpty ?? false)
                          ? group.title!
                          : 'Untitled group',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (group.isAdmin)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.shield_outlined,
                        size: 14,
                        color: Color(0xFF66748A),
                      ),
                    ),
                ],
              ),
              subtitle: Text(
                group.isArchivedBackup
                    ? 'Recovered archive · read only'
                    : group.lastMessage ?? 'No messages yet',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: (group.unreadCount) > 0
                  ? CircleAvatar(
                      radius: 10,
                      backgroundColor: const Color(0xFF245CDB),
                      child: Text(
                        '${group.unreadCount}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    )
                  : group.markedUnread
                  ? const CircleAvatar(
                      radius: 5,
                      backgroundColor: Color(0xFF245CDB),
                    )
                  : const Icon(Icons.chevron_right),
              onLongPress: () => _groupActions(group),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => GroupChatScreen(
                      conversationId: group.id,
                      conversationTitle: group.title ?? 'Group',
                      avatarUrl: group.avatarUrl,
                      secureHistory: widget.secureHistory,
                      readOnlyArchive: group.isArchivedBackup,
                      e2eeEnabled: group.e2eeEnabled,
                    ),
                  ),
                );
                // Refresh group list to update unread count
                refresh();
              },
            ),
          ),
        const Divider(height: 16),
      ],
    );
  }
}

/// Name plus accepted-contact multi-select for group creation.
class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog({required this.contacts});
  final List<CloudContact> contacts;
  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  final name = TextEditingController();
  final selected = <String>{};

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New group'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'e.g. Family',
              border: OutlineInputBorder(),
            ),
          ),
          if (widget.contacts.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'No connected contacts yet. Add people first, or create an empty group.',
                style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
              ),
            ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.contacts.length,
              itemBuilder: (context, i) {
                final contact = widget.contacts[i];
                return CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(contact.name),
                  subtitle: Text('@${contact.username}'),
                  secondary: CircleAvatar(
                    foregroundImage:
                        (contact.avatarUrl != null &&
                            contact.avatarUrl!.isNotEmpty)
                        ? NetworkImage(contact.avatarUrl!)
                        : null,
                    child: Text(
                      contact.name.isEmpty
                          ? '?'
                          : contact.name[0].toUpperCase(),
                    ),
                  ),
                  value: selected.contains(contact.userId),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      selected.add(contact.userId);
                    } else {
                      selected.remove(contact.userId);
                    }
                  }),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (name.text.trim().isEmpty) return;
          Navigator.pop(context, (
            name: name.text.trim(),
            memberIds: selected.toList(),
          ));
        },
        child: const Text('Create'),
      ),
    ],
  );
}

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.heightOf(context) < 520;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(compact ? 18 : 30),
              decoration: const BoxDecoration(
                color: Color(0xFFE4EBFF),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.waving_hand_rounded,
                size: compact ? 40 : 60,
                color: const Color(0xFF245CDB),
              ),
            ),
            SizedBox(height: compact ? 16 : 28),
            Text(
              'Good conversations\nstart with a hello.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: compact ? 26 : 36,
                height: 1.15,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.2,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Choose a conversation, or make a new connection.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF66748A)),
            ),
            const SizedBox(height: 40),
            const Text(
              'PHASE 1 / LOCAL DEMO',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                color: Color(0xFF66748A),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatPane extends StatefulWidget {
  const ChatPane({
    super.key,
    required this.store,
    required this.chat,
    this.onBack,
  });
  final ChatStore store;
  final Conversation chat;
  final VoidCallback? onBack;
  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final composer = TextEditingController();
  final scroll = ScrollController();
  late final ChatPreferences _chatPreferences = ChatPreferences(
    widget.store.preferences,
  );
  late ChatWallpaperPreset _wallpaperPreset;

  @override
  void initState() {
    super.initState();
    _wallpaperPreset = _chatPreferences.wallpaperFor(widget.chat.id);
  }

  @override
  void dispose() {
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  void send() {
    if (composer.text.trim().isEmpty) return;
    widget.store.send(widget.chat, composer.text);
    composer.clear();
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  Future<void> _chooseWallpaper() async {
    final picked = await chooseChatWallpaper(context, _wallpaperPreset);
    if (picked == null || !mounted) return;
    await _chatPreferences.setWallpaper(widget.chat.id, picked);
    setState(() => _wallpaperPreset = picked);
  }

  /// Mute with WhatsApp-style durations. Extracted so narrow screens can
  /// reach it from the overflow menu too.
  Future<void> _muteAction() async {
    if (widget.chat.isMutedNow) {
      await widget.store.toggleMute(widget.chat);
      setState(() {});
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Mute notifications'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '8h'),
            child: const Text('For 8 hours'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '1w'),
            child: const Text('For 1 week'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'always'),
            child: const Text('Always'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    await widget.store.setMute(widget.chat, switch (choice) {
      '8h' => const Duration(hours: 8),
      '1w' => const Duration(days: 7),
      _ => null,
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            if (widget.onBack != null)
              IconButton(
                tooltip: 'Back',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
            ContactAvatar(chat: widget.chat),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.chat.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  Text(
                    'Demo contact',
                    style: TextStyle(
                      color: widget.chat.isTyping
                          ? const Color(0xFF245CDB)
                          : const Color(0xFF66748A),
                      fontSize: 12,
                      fontWeight: widget.chat.isTyping
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            if (MediaQuery.sizeOf(context).width >= 400)
              IconButton(
                tooltip: widget.chat.isMutedNow
                    ? 'Unmute conversation'
                    : 'Mute conversation',
                onPressed: _muteAction,
                icon: Icon(
                  widget.chat.isMutedNow
                      ? Icons.volume_off_outlined
                      : Icons.notifications_outlined,
                ),
              ),
            if (MediaQuery.sizeOf(context).width >= 400)
              IconButton(
                tooltip: 'Chat wallpaper & theme',
                onPressed: _chooseWallpaper,
                icon: const Icon(Icons.wallpaper_outlined),
              ),
            if (MediaQuery.sizeOf(context).width < 400)
              PopupMenuButton<String>(
                tooltip: 'More options',
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'wallpaper':
                      _chooseWallpaper();
                    case 'mute':
                      _muteAction();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'wallpaper',
                    child: Text('Chat wallpaper & theme'),
                  ),
                  PopupMenuItem(
                    value: 'mute',
                    child: Text(
                      widget.chat.isMutedNow ? 'Unmute' : 'Mute notifications',
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      Container(
        width: double.infinity,
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF182229)
            : const Color(0xFFEBF0FC),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Text(
          '💬 Demo conversation · stored only on this device · calls are available in encrypted chats',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white70
                : const Color(0xFF465C85),
          ),
        ),
      ),
      Expanded(
        child: WhatsAppWallpaper(
          preset: _wallpaperPreset,
          child: ListenableBuilder(
            listenable: widget.store,
            builder: (context, _) {
              // Newest-first feed into the reversed list: index 0 renders
              // at the bottom edge, so the newest message sits at the
              // bottom like every messenger.
              final messages = widget.chat.messages.reversed.toList();
              if (messages.isEmpty && !widget.chat.isTyping) {
                return const Center(
                  child: Text('Your conversation starts here. Say hello!'),
                );
              }
              final totalCount =
                  messages.length + (widget.chat.isTyping ? 1 : 0);
              return ListView.builder(
                controller: scroll,
                reverse: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 16,
                ),
                itemCount: totalCount,
                itemBuilder: (context, i) {
                  if (widget.chat.isTyping && i == 0) {
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(left: 12, bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF202C33)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Thinking…',
                              style: TextStyle(
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final messageIndex = widget.chat.isTyping ? i - 1 : i;
                  final message = messages[messageIndex];
                  return WhatsAppBubble(
                    text: message.text,
                    isMine: message.mine,
                    timestamp: message.at,
                    status: MessageDeliveryState.read,
                  );
                },
              );
            },
          ),
        ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1F2C34)
              : const Color(0xFFF0F2F5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(
                Icons.emoji_emotions_outlined,
                color: Colors.grey,
              ),
              onPressed: () async {
                const choices = ['😀', '😂', '❤️', '👍', '🎉', '🙏'];
                final emoji = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Choose emoji'),
                    content: Wrap(
                      spacing: 14,
                      children: choices
                          .map(
                            (value) => InkWell(
                              onTap: () => Navigator.pop(context, value),
                              child: Text(
                                value,
                                style: const TextStyle(fontSize: 30),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                );
                if (emoji != null) {
                  composer.text += emoji;
                  composer.selection = TextSelection.collapsed(
                    offset: composer.text.length,
                  );
                }
              },
            ),
            IconButton(
              tooltip: 'Attachments live in encrypted chats',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Photos, videos, and polls send from encrypted chats.',
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.attach_file, color: Colors.grey),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF2A3942)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: composer,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 4000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Write a message…',
                    counterText: '',
                    border: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) => send(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            CircleAvatar(
              radius: 22,
              backgroundColor: const Color(0xFF00A884),
              child: IconButton(
                tooltip: 'Send message',
                onPressed: send,
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
