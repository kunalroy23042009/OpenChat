import 'package:flutter/material.dart';

enum MessageDeliveryState { pending, sent, delivered, read }

class MessageStatusTicks extends StatelessWidget {
  const MessageStatusTicks({super.key, required this.state, this.size = 16.0});

  final MessageDeliveryState state;
  final double size;

  Widget _icon() {
    switch (state) {
      case MessageDeliveryState.pending:
        return Icon(Icons.access_time, size: size, color: Colors.grey);

      case MessageDeliveryState.sent:
        return Icon(Icons.check, size: size, color: Colors.grey);

      case MessageDeliveryState.delivered:
        return Icon(Icons.done_all, size: size, color: Colors.grey);

      case MessageDeliveryState.read:
        return Icon(Icons.done_all, size: size, color: const Color(0xFF53BDEB));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(scale: anim, child: child),
        ),
        child: KeyedSubtree(
          key: ValueKey(state),
          child: _icon(),
        ),
      );
}

/// Animated three-dot typing indicator.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color});
  final Color? color;
  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Opacity(
                opacity: (0.35 + 0.65 * (((_c.value * 3 - i).clamp(0.0, 1.0)))),
                child: Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.only(right: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color ??
                        Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ),
          ],
        ),
      );
}
