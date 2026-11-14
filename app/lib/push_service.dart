import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api.dart';

/// Thông báo đẩy FCM (app bị tắt hẳn vẫn nhận được). Khi app đang mở, cảnh báo đã tới qua WebSocket và được
/// hiện bằng thông báo cục bộ nên không xử lý tin FCM ở foreground (tránh báo trùng).
/// Mọi lỗi (chưa cấp quyền, simulator không có APNs, thiếu Google Play Services…) đều được bỏ qua: đẩy là tính năng
/// bổ sung, không được làm hỏng app.
class PushService {
  static bool _ready = false;
  static bool _listening = false;
  static String? _token;

  static bool get _supported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  static Future<void> init() async {
    if (_ready || !_supported) return;
    try {
      await Firebase.initializeApp();
      _ready = true;
    } catch (e) {
      debugPrint('PushService.init lỗi: $e');
    }
  }

  /// Đăng ký token của thiết bị cho người dùng đang đăng nhập. Chỉ chạy khi hệ điều hành đã cấp quyền thông báo
  /// (iOS: sau khi người dùng bấm Cho phép; Android < 13: luôn được cấp).
  static Future<void> sync(Api api) async {
    await init();
    if (!_ready) return;
    try {
      final fm = FirebaseMessaging.instance;
      final st = (await fm.getNotificationSettings()).authorizationStatus;
      if (st != AuthorizationStatus.authorized && st != AuthorizationStatus.provisional) return;
      if (Platform.isIOS) {
        // Token FCM trên iOS cần token APNs; ngay sau khi cấp quyền có thể chưa có nên thử lại vài lần.
        for (var i = 0; i < 10 && await fm.getAPNSToken() == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        if (await fm.getAPNSToken() == null) {
          debugPrint('PushService: chưa có token APNs (simulator hoặc thiếu Push Notifications capability).');
          return;
        }
      }
      // Dùng token đăng ký FCM cổ điển (đã được HTTP v1 hỗ trợ); API register()/onRegistered mới trả về FID chưa kiểm chứng.
      // ignore: deprecated_member_use
      final t = await fm.getToken();
      if (t == null) return;
      _token = t;
      await _register(api, t);
      if (!_listening) {
        _listening = true;
        // ignore: deprecated_member_use
        fm.onTokenRefresh.listen((nt) {
          _token = nt;
          _register(api, nt);
        });
      }
    } catch (e) {
      debugPrint('PushService.sync lỗi: $e');
    }
  }

  static Future<void> _register(Api api, String token) async {
    try {
      await api.registerPushToken(token, Platform.isIOS ? 'ios' : 'android');
    } catch (e) {
      debugPrint('PushService: đăng ký token lỗi: $e');
    }
  }

  /// Gỡ token khỏi tài khoản đang đăng xuất (gọi trước khi xoá phiên) để máy này không nhận cảnh báo của người đó nữa.
  static Future<void> unregister(Api api) async {
    final t = _token;
    if (t == null) return;
    try {
      await api.deletePushToken(t).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
