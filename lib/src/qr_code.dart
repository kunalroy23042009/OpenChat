import 'package:flutter/material.dart';

/// Simple QR code widget using CustomPainter (no external dependency).
/// For production use, prefer `qr_flutter` package.
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, this.size = 200});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => Center(
    child: CustomPaint(
      size: Size(size, size),
      painter: _QrPainter(data: data),
    ),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter({required this.data}) : _modules = _encode(data);

  final String data;
  final List<List<bool>> _modules;

  static List<List<bool>> _encode(String data) {
    // Very simplified QR encoding - for real use, use qr_flutter package
    // This draws a placeholder pattern
    const size = 25;
    final modules = List.generate(size, (_) => List.filled(size, false));
    // Draw a simple finder pattern placeholder
    for (int y = 0; y < 7; y++) {
      for (int x = 0; x < 7; x++) {
        if (y == 0 || y == 6 || x == 0 || x == 6 || (y >= 2 && y <= 4 && x >= 2 && x <= 4)) {
          modules[y][x] = true;
          modules[size - 7 + y][x] = true;
          modules[y][size - 7 + x] = true;
        }
      }
    }
    // Scatter data bits
    int bit = 0;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        if (!modules[y][x] && bit < data.length) {
          modules[y][x] = data.codeUnitAt(bit) & 1 == 1;
          bit++;
        }
      }
    }
    return modules;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final moduleSize = size.width / _modules.length;
    final paint = Paint()..color = Colors.black;
    for (int y = 0; y < _modules.length; y++) {
      for (int x = 0; x < _modules[y].length; x++) {
        if (_modules[y][x]) {
          canvas.drawRect(
            Rect.fromLTWH(x * moduleSize, y * moduleSize, moduleSize, moduleSize),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}