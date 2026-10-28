import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../chat_store.dart';
import '../local_profile.dart';
import '../push/push_service.dart';
import 'conversation_repository.dart';
import 'group_chat_screen.dart';

class GroupInvitePreviewScreen extends StatefulWidget {
  const GroupInvitePreviewScreen({
    super.key,
    required this.client,
    required this.store,
    required this.profile,
    required this.push,
    required this.inviteCode,
  });
  final SupabaseClient client;
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  final String inviteCode;

  @override
  State<GroupInvitePreviewScreen> createState() =>
      _GroupInvitePreviewScreenState();
}

class _GroupInvitePreviewScreenState extends State<GroupInvitePreviewScreen> {
  bool _loading = true;
  bool _joining = false;
  String? _error;
  Map<String, dynamic>? _preview;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    try {
      final repo = ConversationRepository(widget.client);
      final preview = await repo.previewGroupInvite(widget.inviteCode);
      if (mounted) {
        setState(() {
          _preview = preview;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Invalid or expired invite link.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _join() async {
    if (_joining) return;
    setState(() => _joining = true);
    try {
      final repo = ConversationRepository(widget.client);
      final groupId = await repo.joinGroupByInvite(widget.inviteCode);
      if (!mounted) return;
      // Get full group details for navigation
      final conversations = repo.conversations;
      final group = conversations.firstWhere((c) => c.id == groupId);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => GroupChatScreen(
            conversationId: group.id,
            conversationTitle: group.title ?? 'Group',
            conversationType: group.type,
            avatarUrl: group.avatarUrl,
            memberCount: group.memberCount,
            secureHistory: widget.store.secureHistory,
            e2eeEnabled: group.e2eeEnabled,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _joining = false;
          _error = 'Could not join group. The invite may have expired or the group is full.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Group Invite')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: Colors.red),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Go back'),
                        ),
                      ],
                    ),
                  ),
                )
              : _preview == null
                  ? const Center(child: Text('Unknown invite'))
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          CircleAvatar(
                            radius: 40,
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Text(
                              _preview!['title']?.toString().substring(0, 1).toUpperCase() ?? '?',
                              style: theme.textTheme.headlineLarge?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _preview!['title']?.toString() ?? 'Unnamed group',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall,
                          ),
                          if (_preview!['description']?.toString().isNotEmpty == true) ...[
                            const SizedBox(height: 8),
                            Text(
                              _preview!['description'].toString(),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.group_outlined,
                                  size: 18,
                                  color: theme.colorScheme.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Text(
                                '${_preview!['member_count'] ?? 0} members',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          if (_preview!['require_approval'] == true) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                'Requires admin approval',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 32),
                          FilledButton(
                            onPressed: _joining ? null : _join,
                            child: _joining
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text('Join Group'),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _joining
                                ? null
                                : () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ),
    );
  }
}