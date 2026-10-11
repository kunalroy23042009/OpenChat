import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'status_ticks.dart';

class WhatsAppBubble extends StatelessWidget {
  const WhatsAppBubble({
    super.key,
    required this.text,
    required this.isMine,
    required this.timestamp,
    this.status = MessageDeliveryState.delivered,
    this.replyToText,
    this.replyToSender,
    this.reactions = const [],
    this.onReact,
    this.onReply,
  });

  final String text;
  final bool isMine;
  final DateTime timestamp;
  final MessageDeliveryState status;
  final String? replyToText;
  final String? replyToSender;
  final List<String> reactions;
  final ValueChanged<String>? onReact;
  final VoidCallback? onReply;

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  void _showReactionMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1F2C34)
              : Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final emoji in ['❤️', '👍', '😂', '😮', '😢', '🙏'])
              GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  onReact?.call(emoji);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(emoji, style: const TextStyle(fontSize: 28)),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              tooltip: 'Copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Message copied')),
                );
              },
            ),
            if (onReply != null)
              IconButton(
                icon: const Icon(Icons.reply, size: 20),
                tooltip: 'Reply',
                onPressed: () {
                  Navigator.pop(ctx);
                  onReply?.call();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // WhatsApp authentic bubble colors
    final bubbleColor = isMine
        ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFE7FFDB))
        : (isDark ? const Color(0xFF202C33) : Colors.white);

    final textColor = isDark ? Colors.white : const Color(0xFF111B21);
    final timeColor = isDark ? Colors.white60 : const Color(0xFF667781);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showReactionMenu(context),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(isMine ? 12 : 2),
              bottomRight: Radius.circular(isMine ? 2 : 12),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Replied message quote banner
              if (replyToText != null) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (isDark ? Colors.black26 : Colors.black.withValues(alpha: 0.04)),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(
                      left: BorderSide(
                        color: isMine ? const Color(0xFF25D366) : const Color(0xFF34B7F1),
                        width: 4,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        replyToSender ?? (isMine ? 'You' : 'Contact'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isMine ? const Color(0xFF25D366) : const Color(0xFF34B7F1),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        replyToText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.8)),
                      ),
                    ],
                  ),
                ),
              ],

              // Message text & metadata layout
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  Text(
                    text,
                    style: TextStyle(fontSize: 15, color: textColor, height: 1.25),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(timestamp),
                        style: TextStyle(fontSize: 11, color: timeColor),
                      ),
                      if (isMine) ...[
                        const SizedBox(width: 4),
                        MessageStatusTicks(state: status, size: 15),
                      ],
                    ],
                  ),
                ],
              ),

              // Attached reactions badge
              if (reactions.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF111B21) : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark ? const Color(0xFF2A3942) : Colors.black12,
                    ),
                  ),
                  child: Text(
                    reactions.join(' '),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class WhatsAppAttachmentSheet extends StatelessWidget {
  const WhatsAppAttachmentSheet({super.key, required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final items = [
      {'label': 'Document', 'icon': Icons.insert_drive_file, 'color': const Color(0xFF7F66FF)},
      {'label': 'Camera', 'icon': Icons.camera_alt, 'color': const Color(0xFFD3396D)},
      {'label': 'Gallery', 'icon': Icons.image, 'color': const Color(0xFFAC44CF)},
      {'label': 'Audio', 'icon': Icons.headphones, 'color': const Color(0xFFFF6500)},
      {'label': 'Location', 'icon': Icons.location_on, 'color': const Color(0xFF0F9D58)},
      {'label': 'Contact', 'icon': Icons.person, 'color': const Color(0xFF009EE6)},
      {'label': 'Poll', 'icon': Icons.bar_chart, 'color': const Color(0xFF00A884)},
    ];

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 0.85,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          final color = item['color'] as Color;
          final icon = item['icon'] as IconData;
          final label = item['label'] as String;

          return GestureDetector(
            onTap: () {
              Navigator.pop(context);
              onPick(label);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: color,
                  child: Icon(icon, color: Colors.white, size: 24),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : const Color(0xFF54656F),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
