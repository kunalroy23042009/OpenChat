import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'formatted_text.dart';
import 'status_ticks.dart';

/// Plays a short fade-and-rise the first time a keyed item appears (new
/// message or row), then stays static across rebuilds. A process-wide
/// seen-set keyed by widget key means tick updates, reactions, and theme
/// changes never replay the animation.
class AppearOnce extends StatefulWidget {
  const AppearOnce({super.key, required this.child});
  final Widget child;
  @override
  State<AppearOnce> createState() => _AppearOnceState();
}

class _AppearOnceState extends State<AppearOnce>
    with SingleTickerProviderStateMixin {
  static final Set<String> _seen = {};
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    final firstSight = _seen.add(widget.key.toString());
    if (_seen.length > 2000) _seen.clear();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _opacity = curve;
    _offset = Tween(begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(curve);
    if (firstSight) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _opacity,
        child: SlideTransition(position: _offset, child: widget.child),
      );
}

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

  Widget _buildBubble(BuildContext context, bool isDark) => Align(
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
              color: isMine
                  ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFE7FFDB))
                  : (isDark ? const Color(0xFF202C33) : Colors.white),
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
                          style: TextStyle(fontSize: 12, color: (isDark ? Colors.white : const Color(0xFF111B21)).withValues(alpha: 0.8)),
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
                    FormattedText(
                      text: text,
                      baseStyle: TextStyle(fontSize: 15, color: isDark ? Colors.white : const Color(0xFF111B21), height: 1.25),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(timestamp),
                          style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : const Color(0xFF667781)),
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bubble = _buildBubble(context, isDark);
    if (onReply == null) return bubble;
    return Dismissible(
      key: ValueKey(text),
      direction: isMine ? DismissDirection.startToEnd : DismissDirection.endToStart,
      background: _WhatsAppReplySwipeBackground(isMine: isMine),
      onDismissed: (_) => onReply?.call(),
      child: bubble,
    );
  }
}

class _WhatsAppReplySwipeBackground extends StatelessWidget {
  const _WhatsAppReplySwipeBackground({required this.isMine});
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF004D3A) : const Color(0xFFDCF8C6),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(12),
          topRight: const Radius.circular(12),
          bottomLeft: Radius.circular(isMine ? 12 : 2),
          bottomRight: Radius.circular(isMine ? 2 : 12),
        ),
      ),
      alignment: isMine ? Alignment.centerLeft : Alignment.centerRight,
      child: Icon(
        Icons.reply,
        color: isDark ? const Color(0xFF25D366) : const Color(0xFF008069),
        size: 28,
      ),
    );
  }
}