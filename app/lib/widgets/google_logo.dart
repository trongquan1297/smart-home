import 'package:flutter/material.dart';

/// Logo "G" nhiều màu của Google (đường vẽ của nút Sign in with Google, khung 48×48), vẽ vector để luôn nét.
/// Chỉ dùng cho nút đăng nhập bằng Google, theo hướng dẫn thương hiệu của Google.
class GoogleLogo extends StatelessWidget {
  final double size;
  const GoogleLogo({super.key, this.size = 20});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _GooglePainter()),
  );
}

class _GooglePainter extends CustomPainter {
  static const _parts = <(int, String)>[
    (0xFFEA4335, 'M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z'),
    (0xFF4285F4, 'M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z'),
    (0xFFFBBC05, 'M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z'),
    (0xFF34A853, 'M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z'),
  ];
  static final _paths = [for (final (_, d) in _parts) _parseSvgPath(d)];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48, size.height / 48);
    for (var i = 0; i < _parts.length; i++) {
      canvas.drawPath(_paths[i], Paint()..color = Color(_parts[i].$1));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Bộ đọc path SVG tối giản cho các lệnh dùng ở trên: M/m L/l H/h V/v C/c S/s Z/z.
Path _parseSvgPath(String d) {
  final tokens = RegExp(r'[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)').allMatches(d).map((m) => m.group(0)!).toList();
  final path = Path();
  var i = 0;
  var cmd = '';
  double x = 0, y = 0, cx2 = 0, cy2 = 0;
  double n() => double.parse(tokens[i++]);
  bool isNum() => i < tokens.length && !RegExp(r'^[A-Za-z]$').hasMatch(tokens[i]);
  while (i < tokens.length) {
    if (!isNum()) cmd = tokens[i++];
    final rel = cmd == cmd.toLowerCase();
    final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
    switch (cmd.toLowerCase()) {
      case 'm':
        x = ox + n();
        y = oy + n();
        path.moveTo(x, y);
        cmd = rel ? 'l' : 'L'; // cặp số tiếp theo sau M là lệnh L
      case 'l':
        x = ox + n();
        y = oy + n();
        path.lineTo(x, y);
      case 'h':
        x = ox + n();
        path.lineTo(x, y);
      case 'v':
        y = oy + n();
        path.lineTo(x, y);
      case 'c':
        final x1 = ox + n(), y1 = oy + n();
        cx2 = ox + n();
        cy2 = oy + n();
        x = ox + n();
        y = oy + n();
        path.cubicTo(x1, y1, cx2, cy2, x, y);
      case 's':
        final x1 = 2 * x - cx2, y1 = 2 * y - cy2; // đối xứng điểm điều khiển trước
        cx2 = ox + n();
        cy2 = oy + n();
        x = ox + n();
        y = oy + n();
        path.cubicTo(x1, y1, cx2, cy2, x, y);
      case 'z':
        path.close();
      default:
        i++; // lệnh không hỗ trợ: bỏ qua
    }
    if (cmd.toLowerCase() != 'c' && cmd.toLowerCase() != 's') {
      cx2 = x;
      cy2 = y;
    }
  }
  return path;
}
