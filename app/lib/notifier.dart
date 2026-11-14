import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thông báo trên thiết bị khi có cảnh báo cảm biến từ máy chủ (nhận qua WebSocket lúc app đang chạy, kể cả khi ở nền
/// nếu hệ điều hành chưa đóng app). Thông báo đẩy khi app đã bị tắt hẳn cần FCM/APNs (xem README).
class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static const _channel = AndroidNotificationChannel(
    'alerts',
    'Cảnh báo cảm biến',
    description: 'Cảm biến hiện diện / cửa ra vào được kích hoạt trong ngữ cảnh đang bật',
    importance: Importance.high,
  );

  static Future<void> init() async {
    if (_ready || kIsWeb || !(Platform.isIOS || Platform.isAndroid)) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Không hỏi quyền ngay khi mở app: hỏi đúng lúc người dùng bật cảnh báo cho một ngữ cảnh.
          iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
        ),
      );
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(_channel);
      _ready = true;
    } catch (e) {
      debugPrint('Notifier.init lỗi: $e');
    }
  }

  /// Hỏi quyền hiển thị thông báo (iOS: hộp thoại hệ thống; Android 13+: POST_NOTIFICATIONS). Trả về true nếu được cấp.
  static Future<bool> requestPermission() async {
    await init();
    if (!_ready) return false;
    try {
      if (Platform.isIOS) {
        return await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      }
      return await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission() ?? true;
    } catch (e) {
      debugPrint('Notifier.requestPermission lỗi: $e');
      return false;
    }
  }

  static Future<void> show(int id, String title, String body) async {
    await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true, presentBanner: true, presentList: true),
        ),
      );
    } catch (e) {
      debugPrint('Notifier.show lỗi: $e');
    }
  }
}
