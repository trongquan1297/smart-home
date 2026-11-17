import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

/// Màu chủ đạo: xanh da trời nhạt (sáng/tối đều dùng chung seed).
const brandSeed = Color(0xFF38BDF8);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final seeded = ColorScheme.fromSeed(seedColor: brandSeed, brightness: brightness, dynamicSchemeVariant: DynamicSchemeVariant.fidelity);
  // Chế độ sáng: ép primary về đúng xanh da trời tươi (bộ pha màu tự động thường làm tối đi).
  final scheme = dark
      ? seeded
      : seeded.copyWith(
          primary: const Color(0xFF0EA5E9),
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFE0F2FE),
          onPrimaryContainer: const Color(0xFF075985),
        );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final pageBg = dark ? const Color(0xFF0B1016) : const Color(0xFFF4F7FB);
  final cardBg = dark ? const Color(0xFF141B24) : Colors.white;
  final text = base.textTheme;

  return base.copyWith(
    scaffoldBackgroundColor: pageBg,
    // Chữ tiêu đề đậm, khít hơn: nhìn hiện đại và đỡ phải dùng nhiều chữ mô tả.
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -.4),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -.3),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -.1),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
      backgroundColor: cardBg,
      selectedColor: scheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: cardBg,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
    ),
    listTileTheme: ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? const Icon(Icons.check_rounded, size: 16) : null),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: .4), space: 24),
    appBarTheme: AppBarTheme(
      backgroundColor: pageBg, // đặc để nội dung cuộn không chui dưới tiêu đề
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: cardBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? .25 : .35)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1A2330) : const Color(0xFFEEF2F8),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      backgroundColor: cardBg,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      extendedTextStyle: const TextStyle(fontWeight: FontWeight.w700),
    ),
    popupMenuTheme: PopupMenuThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder(), TargetPlatform.iOS: CupertinoPageTransitionsBuilder()},
    ),
  );
}

/// Nền gradient nhẹ dùng cho màn đăng nhập / tiêu đề.
BoxDecoration brandGradient(BuildContext context) {
  final c = Theme.of(context).colorScheme;
  return BoxDecoration(
    gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c.primary, Color.lerp(c.primary, const Color(0xFF60A5FA), .55)!]),
  );
}
