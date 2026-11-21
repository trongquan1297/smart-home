import 'package:flutter/material.dart';

/// Bảng màu gradient cho biểu tượng theo ngữ nghĩa — để mỗi loại chức năng nhận ra ngay bằng màu.
class Vivid {
  static const scene = [Color(0xFF8B5CF6), Color(0xFFEC4899)];
  static const alert = [Color(0xFFF97316), Color(0xFFEF4444)];
  static const leave = [Color(0xFF3B82F6), Color(0xFF6366F1)];
  static const speak = [Color(0xFFEC4899), Color(0xFFF43F5E)];
  static const timer = [Color(0xFFF59E0B), Color(0xFFF97316)];
  static const link = [Color(0xFF14B8A6), Color(0xFF06B6D4)];
  static const device = [Color(0xFF10B981), Color(0xFF0EA5E9)];
  static const location = [Color(0xFF6366F1), Color(0xFF8B5CF6)];
  static const members = [Color(0xFF0EA5E9), Color(0xFF6366F1)];
  static const gateway = [Color(0xFF475569), Color(0xFF0EA5E9)];
  static const matter = [Color(0xFF22C55E), Color(0xFF14B8A6)];
  static const bell = [Color(0xFFF59E0B), Color(0xFFEF4444)];
  static const power = [Color(0xFF10B981), Color(0xFF22C55E)];
  static const schedule = [Color(0xFF0EA5E9), Color(0xFF22D3EE)];
  static const info = [Color(0xFF0EA5E9), Color(0xFF6366F1)];
  static const danger = [Color(0xFFEF4444), Color(0xFFF43F5E)];
  static const water = [Color(0xFF06B6D4), Color(0xFF3B82F6)];
}

/// Màu gradient theo biểu tượng ngữ cảnh (id của SceneKind).
List<Color> sceneColors(String id) => switch (id) {
  'home' => const [Color(0xFFF59E0B), Color(0xFFF97316)],
  'bed' => const [Color(0xFF6366F1), Color(0xFF8B5CF6)],
  'sun' => const [Color(0xFFFBBF24), Color(0xFFF97316)],
  'moon' => const [Color(0xFF1E3A8A), Color(0xFF6366F1)],
  'away' => const [Color(0xFF3B82F6), Color(0xFF06B6D4)],
  'movie' => const [Color(0xFFEF4444), Color(0xFFEC4899)],
  'party' => const [Color(0xFFEC4899), Color(0xFF8B5CF6)],
  'work' => const [Color(0xFF0EA5E9), Color(0xFF14B8A6)],
  'eco' => const [Color(0xFF22C55E), Color(0xFF10B981)],
  'lock' => const [Color(0xFF475569), Color(0xFF0EA5E9)],
  _ => Vivid.scene,
};

/// Màu gradient theo loại phòng (id của RoomKind).
List<Color> roomColors(String? id) => switch (id) {
  'living' => const [Color(0xFFF97316), Color(0xFFF59E0B)],
  'bedroom' => const [Color(0xFF6366F1), Color(0xFF8B5CF6)],
  'kitchen' => const [Color(0xFFEF4444), Color(0xFFF97316)],
  'bathroom' => const [Color(0xFF06B6D4), Color(0xFF3B82F6)],
  'dining' => const [Color(0xFFF59E0B), Color(0xFFEAB308)],
  'office' => const [Color(0xFF0EA5E9), Color(0xFF6366F1)],
  'balcony' => const [Color(0xFF22C55E), Color(0xFF14B8A6)],
  'garage' => const [Color(0xFF64748B), Color(0xFF475569)],
  'kids' => const [Color(0xFFEC4899), Color(0xFFF472B6)],
  'laundry' => const [Color(0xFF14B8A6), Color(0xFF0EA5E9)],
  'hallway' => const [Color(0xFFA855F7), Color(0xFF6366F1)],
  null => const [Color(0xFF94A3B8), Color(0xFF64748B)],
  _ => Vivid.device,
};

/// Nhãn nhỏ dạng viên thuốc: biểu tượng + chữ ngắn (thay cho câu mô tả).
class Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const Pill(this.icon, this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: .1), borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c),
            ),
          ),
        ],
      ),
    );
  }
}

/// Biểu tượng trong ô vuông bo góc nền gradient (thay cho icon đơn sắc).
class IconBadge extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final double size;
  final bool muted;
  const IconBadge(this.icon, {super.key, this.colors = Vivid.device, this.size = 36, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Không nền: chỉ tô màu gradient lên chính biểu tượng, giữ nguyên ô kích thước để bố cục không xê dịch.
    final glyph = Icon(icon, size: size * .78, color: muted ? cs.onSurfaceVariant : Colors.white);
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: muted
            ? glyph
            : ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors).createShader(r),
                child: glyph,
              ),
      ),
    );
  }
}

/// Nút hành động chính (thêm…) đặt trên thanh tiêu đề, thay cho nút nổi ở góc dưới.
class HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget? child; // thay biểu tượng, ví dụ vòng quay khi đang xử lý
  const HeaderAction({super.key, required this.icon, required this.tooltip, required this.onPressed, this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Thanh tiêu đề ép màu biểu tượng theo actionsIconTheme: đặt màu trực tiếp để nút nền đậm vẫn có biểu tượng trắng.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: IconButton.filled(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(backgroundColor: cs.primary, foregroundColor: cs.onPrimary, fixedSize: const Size(42, 42)),
        icon: child ?? Icon(icon, size: 22, color: onPressed == null ? null : cs.onPrimary),
      ),
    );
  }
}

/// Mở popup ở giữa màn hình (thay cho bảng trượt từ dưới lên).
/// Nội dung bên trong không cần tự cộng khoảng bàn phím hay vùng an toàn: Dialog đã lo.
Future<T?> showCenterSheet<T>({required BuildContext context, required WidgetBuilder builder, bool barrierDismissible = true, double topPadding = 20}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (c) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: MediaQuery.removePadding(
          context: c,
          removeTop: true,
          removeBottom: true,
          removeLeft: true,
          removeRight: true,
          child: MediaQuery.removeViewInsets(
            context: c,
            removeBottom: true,
            child: Padding(
              padding: EdgeInsets.only(top: topPadding),
              child: Builder(builder: builder),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Mở bảng giải thích (thay cho đoạn mô tả dài hiện thẳng trên màn hình).
Future<void> showInfo(
  BuildContext context, {
  required String title,
  required String text,
  IconData icon = Icons.lightbulb_rounded,
  List<Color> colors = Vivid.info,
}) {
  final tt = Theme.of(context).textTheme;
  return showCenterSheet<void>(
    context: context,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge(icon, colors: colors, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(text, style: tt.bodyMedium?.copyWith(height: 1.45)),
          ],
        ),
      ),
    ),
  );
}

/// Nút "i" nhỏ: chạm để xem giải thích.
class InfoTip extends StatelessWidget {
  final String title;
  final String text;
  final double size;
  const InfoTip(this.title, this.text, {super.key, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.info_outline_rounded, size: size),
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      tooltip: 'Giải thích',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tight(Size.square(size + 18)),
      onPressed: () => showInfo(context, title: title, text: text),
    );
  }
}

/// Tiêu đề mục: biểu tượng màu + chữ đậm + nút "i" (tuỳ chọn) + phần bên phải (tuỳ chọn).
class SectionHeader extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final String title;
  final String? info;
  final Widget? trailing;
  const SectionHeader({super.key, required this.icon, required this.colors, required this.title, this.info, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          IconBadge(icon, colors: colors, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
                if (info != null) InfoTip(title, info!),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Trạng thái trống: biểu tượng lớn + tiêu đề ngắn (+ "i" giải thích, + nút hành động).
class EmptyState extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final String title;
  final String? info;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.colors, required this.title, this.info, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
      child: Column(
        children: [
          IconBadge(icon, colors: colors, size: 76),
          const SizedBox(height: 18),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              if (info != null) InfoTip(title, info!),
            ],
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
