import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full WhatsApp-style message action menu triggered on long-press.
///
/// Includes: React, Reply, Edit, Forward, Star, Pin, Delete, Copy, Info.
class MessageActionsSheet extends StatelessWidget {
  const MessageActionsSheet({
    super.key,
    required this.messageText,
    required this.isMine,
    required this.isEditable,
    required this.isStarred,
    required this.isPinned,
    this.onReact,
    this.onMoreReactions,
    this.onReply,
    this.onEdit,
    this.onForward,
    this.onStar,
    this.onPin,
    this.onDeleteForMe,
    this.onDeleteForEveryone,
    this.onInfo,
    this.onConvertToTask,
  });

  final String messageText;
  final bool isMine;
  final bool isEditable;
  final bool isStarred;
  final bool isPinned;
  final ValueChanged<String>? onReact;
  final VoidCallback? onMoreReactions;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onForward;
  final VoidCallback? onStar;
  final VoidCallback? onPin;
  final VoidCallback? onDeleteForMe;
  final VoidCallback? onDeleteForEveryone;
  final VoidCallback? onInfo;
  final VoidCallback? onConvertToTask;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1F2C34) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF111B21);
    final subtleColor = isDark ? Colors.white38 : const Color(0xFF8696A0);

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: subtleColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Emoji reaction bar
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF111B21) : const Color(0xFFF0F2F5),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final emoji in ['👍', '❤️', '😂', '😮', '😢', '🙏'])
                  _EmojiButton(
                    emoji: emoji,
                    onTap: () {
                      Navigator.pop(context);
                      onReact?.call(emoji);
                    },
                  ),
                // Full emoji picker trigger
                GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    onMoreReactions?.call();
                  },
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark
                          ? const Color(0xFF2A3942)
                          : const Color(0xFFE9EDEF),
                    ),
                    child: Icon(
                      Icons.add,
                      size: 20,
                      color: isDark ? Colors.white60 : const Color(0xFF54656F),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Action items
          if (onReply != null)
            _ActionTile(
              icon: Icons.reply,
              label: 'Reply',
              color: textColor,
              onTap: () {
                Navigator.pop(context);
                onReply?.call();
              },
            ),

          if (isMine && isEditable)
            _ActionTile(
              icon: Icons.edit,
              label: 'Edit',
              color: textColor,
              onTap: () {
                Navigator.pop(context);
                onEdit?.call();
              },
            ),

          if (onForward != null)
            _ActionTile(
              icon: Icons.forward,
              label: 'Forward',
              color: textColor,
              onTap: () {
                Navigator.pop(context);
                onForward?.call();
              },
            ),

          if (onStar != null)
            _ActionTile(
              icon: isStarred ? Icons.star : Icons.star_outline,
              label: isStarred ? 'Unstar' : 'Star',
              color: textColor,
              onTap: () {
                Navigator.pop(context);
                onStar?.call();
              },
            ),

          if (onPin != null)
            _ActionTile(
              icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              label: isPinned ? 'Unpin' : 'Pin',
              color: textColor,
              onTap: () {
                Navigator.pop(context);
                onPin?.call();
              },
            ),

          if (onConvertToTask != null)
            _ActionTile(
              icon: Icons.task_alt,
              label: 'Convert to task',
              color: textColor,
              onTap: () {
                Navigator.pop(context);
                onConvertToTask?.call();
              },
            ),

          _ActionTile(
            icon: Icons.copy,
            label: 'Copy',
            color: textColor,
            onTap: () {
              Clipboard.setData(ClipboardData(text: messageText));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Message copied'),
                  behavior: SnackBarBehavior.floating,
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),

          if (isMine && onInfo != null)
            _ActionTile(
              icon: Icons.info_outline,
              label: 'Info',
              color: textColor,
              onTap: () {
                Navigator.pop(context);
                onInfo?.call();
              },
            ),

          const Divider(height: 1),

          if (onDeleteForMe != null)
            _ActionTile(
              icon: Icons.delete_outline,
              label: 'Delete for me',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                onDeleteForMe?.call();
              },
            ),

          if (isMine && onDeleteForEveryone != null)
            _ActionTile(
              icon: Icons.delete_forever,
              label: 'Delete for everyone',
              color: Colors.red,
              onTap: () {
                Navigator.pop(context);
                onDeleteForEveryone?.call();
              },
            ),

          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}

class _EmojiButton extends StatelessWidget {
  const _EmojiButton({required this.emoji, required this.onTap});
  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(emoji, style: const TextStyle(fontSize: 28)),
    ),
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: color, size: 22),
    title: Text(label, style: TextStyle(color: color, fontSize: 15)),
    dense: true,
    visualDensity: VisualDensity.compact,
    onTap: onTap,
  );
}

/// Shows the full message info sheet with sent/delivered/read timestamps.
class MessageInfoSheet extends StatelessWidget {
  const MessageInfoSheet({
    super.key,
    required this.messageText,
    required this.sentAt,
    this.deliveredAt,
    this.readAt,
    this.editedAt,
    this.isEdited = false,
  });

  final String messageText;
  final DateTime sentAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final DateTime? editedAt;
  final bool isEdited;

  String _fmt(DateTime dt) =>
      '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black26,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Message info',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : const Color(0xFF111B21),
            ),
          ),
          const SizedBox(height: 16),
          _InfoRow(
            icon: Icons.access_time,
            iconColor: const Color(0xFF667781),
            label: 'Sent',
            value: _fmt(sentAt),
          ),
          if (deliveredAt != null)
            _InfoRow(
              icon: Icons.done_all,
              iconColor: const Color(0xFF667781),
              label: 'Delivered',
              value: _fmt(deliveredAt!),
            ),
          if (readAt != null)
            _InfoRow(
              icon: Icons.done_all,
              iconColor: const Color(0xFF34B7F1),
              label: 'Read',
              value: _fmt(readAt!),
            ),
          if (isEdited && editedAt != null)
            _InfoRow(
              icon: Icons.edit,
              iconColor: const Color(0xFF667781),
              label: 'Edited',
              value: _fmt(editedAt!),
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white70 : const Color(0xFF667781),
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white : const Color(0xFF111B21),
            ),
          ),
        ],
      ),
    );
  }
}
