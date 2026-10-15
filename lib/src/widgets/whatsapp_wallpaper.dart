import 'package:flutter/material.dart';

import '../chat_preferences.dart';

/// Authentic WhatsApp chat wallpaper with subtle background doodles.
class WhatsAppWallpaper extends StatelessWidget {
  const WhatsAppWallpaper({super.key, required this.child, this.preset});

  final Widget child;
  final ChatWallpaperPreset? preset;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = preset ?? ChatWallpaperPreset.classic;
    final bgColor = selected.background(context);

    return Container(
      color: bgColor,
      child: selected.hasDoodles
          ? CustomPaint(
              painter: _WhatsAppDoodlePainter(isDark: isDark),
              child: child,
            )
          : child,
    );
  }
}

class _WhatsAppDoodlePainter extends CustomPainter {
  _WhatsAppDoodlePainter({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (isDark ? Colors.white : const Color(0xFF6B7B87)).withValues(
        alpha: isDark ? 0.04 : 0.07,
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    final fillPaint = Paint()
      ..color = (isDark ? Colors.white : const Color(0xFF6B7B87)).withValues(
        alpha: isDark ? 0.03 : 0.05,
      )
      ..style = PaintingStyle.fill;

    const patternWidth = 120.0;
    const patternHeight = 120.0;

    for (double x = 0; x < size.width; x += patternWidth) {
      for (double y = 0; y < size.height; y += patternHeight) {
        _drawDoodleTile(canvas, Offset(x, y), paint, fillPaint);
      }
    }
  }

  void _drawDoodleTile(Canvas canvas, Offset origin, Paint stroke, Paint fill) {
    // 1. Chat bubble
    final bubbleRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(origin.dx + 15, origin.dy + 15, 24, 16),
      const Radius.circular(5),
    );
    canvas.drawRRect(bubbleRect, stroke);

    // 2. Coffee cup
    final cupRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(origin.dx + 70, origin.dy + 20, 16, 18),
      const Radius.circular(3),
    );
    canvas.drawRRect(cupRect, stroke);
    canvas.drawArc(
      Rect.fromLTWH(origin.dx + 84, origin.dy + 23, 8, 10),
      -1.5,
      3.0,
      false,
      stroke,
    );

    // 3. Heart
    final heartPath = Path()
      ..moveTo(origin.dx + 30, origin.dy + 75)
      ..cubicTo(
        origin.dx + 20,
        origin.dy + 60,
        origin.dx + 10,
        origin.dy + 75,
        origin.dx + 30,
        origin.dy + 92,
      )
      ..cubicTo(
        origin.dx + 50,
        origin.dy + 75,
        origin.dx + 40,
        origin.dy + 60,
        origin.dx + 30,
        origin.dy + 75,
      );
    canvas.drawPath(heartPath, fill);
    canvas.drawPath(heartPath, stroke);

    // 4. Star
    final starCenter = Offset(origin.dx + 85, origin.dy + 80);
    canvas.drawCircle(starCenter, 2.5, fill);
    canvas.drawLine(
      Offset(starCenter.dx - 6, starCenter.dy),
      Offset(starCenter.dx + 6, starCenter.dy),
      stroke,
    );
    canvas.drawLine(
      Offset(starCenter.dx, starCenter.dy - 6),
      Offset(starCenter.dx, starCenter.dy + 6),
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _WhatsAppDoodlePainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}
