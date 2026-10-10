import 'package:flutter/material.dart';

enum MessageDeliveryState {
  pending,
  sent,
  delivered,
  read,
}

class MessageStatusTicks extends StatelessWidget {
  const MessageStatusTicks({
    super.key,
    required this.state,
    this.size = 16.0,
  });

  final MessageDeliveryState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case MessageDeliveryState.pending:
        return Icon(
          Icons.access_time,
          size: size,
          color: Colors.grey,
        );

      case MessageDeliveryState.sent:
        return Icon(
          Icons.check,
          size: size,
          color: Colors.grey,
        );

      case MessageDeliveryState.delivered:
        return Icon(
          Icons.done_all,
          size: size,
          color: Colors.grey,
        );

      case MessageDeliveryState.read:
        return Icon(
          Icons.done_all,
          size: size,
          color: const Color(0xFF34D399), // WhatsApp Blue / Green tick accent
        );
    }
  }
}
