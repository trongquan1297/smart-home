import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api.dart';
import 'models.dart';

const _prefix = 'home-';

/// Callback chạy ở nền (kể cả khi app đã tắt) mỗi khi điện thoại vào/ra vùng căn hộ: báo "trong/ngoài" lên máy chủ.
/// Máy chủ quyết định có chạy ngữ cảnh "rời nhà" hay không (khi người cuối cùng rời đi). Không gửi toạ độ.
@pragma('vm:entry-point')
Future<void> homeGeofenceTriggered(GeofenceCallbackParams params) async {
  final inside = params.event != GeofenceEvent.exit;
  const storage = FlutterSecureStorage();
  final api = Api()
    ..token = await storage.read(key: 'token')
    ..refreshToken = await storage.read(key: 'refresh_token')
    ..onTokens = (a, r) async {
      await storage.write(key: 'token', value: a);
      await storage.write(key: 'refresh_token', value: r);
    };
  if (api.refreshToken == null) return; // đã đăng xuất
  for (final g in params.geofences) {
    if (!g.id.startsWith(_prefix)) continue;
    try {
      await api.ensureFresh();
      await api.reportPresence(g.id.substring(_prefix.length), inside);
    } catch (e) {
      debugPrint('geofence: báo vị trí lỗi: $e'); // callback phải kết thúc nhanh (iOS chờ tối đa 60 giây)
    }
  }
}

/// Theo dõi vùng quanh căn hộ bằng geofence của hệ điều hành (ít tốn pin). Cần quyền vị trí "Luôn luôn".
class GeofenceService {
  static bool get supported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);
  static bool _inited = false;

  static Future<bool> hasAlways() async {
    if (!supported) return false;
    if (Platform.isIOS) return await Geolocator.checkPermission() == LocationPermission.always;
    return await Permission.locationAlways.isGranted;
  }

  /// Xin quyền theo từng bước (iOS: "Khi dùng app" rồi nâng lên "Luôn luôn"; Android 11+: màn hình cài đặt riêng cho nền).
  static Future<bool> requestAlways() async {
    if (!supported) return false;
    try {
      var p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return false;
      if (Platform.isIOS) {
        if (p == LocationPermission.whileInUse) p = await Geolocator.requestPermission();
        return p == LocationPermission.always;
      }
      return (await Permission.locationAlways.request()).isGranted;
    } catch (e) {
      debugPrint('GeofenceService.requestAlways lỗi: $e');
      return false;
    }
  }

  /// Vị trí hiện tại (cần quyền "Khi dùng app"); null nếu bị từ chối hoặc tắt dịch vụ vị trí.
  static Future<Position?> currentPosition() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
    } catch (e) {
      debugPrint('GeofenceService.currentPosition lỗi: $e');
      return null;
    }
  }

  static Future<void> _init() async {
    if (_inited) return;
    await NativeGeofenceManager.instance.initialize();
    _inited = true;
  }

  /// Đăng ký (hoặc đăng ký lại) geofence của căn hộ và báo ngay trạng thái hiện tại. Trả false nếu thiếu quyền "Luôn luôn".
  static Future<bool> enable(Api api, Home home) async {
    if (!supported || !home.hasLocation) return false;
    if (!await hasAlways()) return false;
    try {
      await _init();
      final id = '$_prefix${home.id}';
      try {
        await NativeGeofenceManager.instance.removeGeofenceById(id);
      } catch (_) {}
      await NativeGeofenceManager.instance.createGeofence(
        Geofence(
          id: id,
          location: Location(latitude: home.geoLat!, longitude: home.geoLng!),
          radiusMeters: home.geoRadius.toDouble(),
          triggers: {GeofenceEvent.enter, GeofenceEvent.exit},
          iosSettings: IosGeofenceSettings(initialTrigger: true),
          androidSettings: AndroidGeofenceSettings(initialTriggers: {GeofenceEvent.enter}, notificationResponsiveness: const Duration(seconds: 30)),
        ),
        homeGeofenceTriggered,
      );
      // Báo trạng thái hiện tại để máy chủ biết ai đang ở nhà ngay từ đầu (geofence chỉ báo khi có thay đổi).
      final pos = await currentPosition();
      if (pos != null) {
        final d = Geolocator.distanceBetween(pos.latitude, pos.longitude, home.geoLat!, home.geoLng!);
        await api.reportPresence(home.id, d <= home.geoRadius);
      }
      return true;
    } catch (e) {
      debugPrint('GeofenceService.enable lỗi: $e');
      return false;
    }
  }

  static Future<void> disable(Home home) async {
    if (!supported) return;
    try {
      await _init();
      await NativeGeofenceManager.instance.removeGeofenceById('$_prefix${home.id}');
    } catch (_) {}
  }

  /// Xoá mọi geofence (khi đăng xuất, để máy này không báo vị trí cho tài khoản khác).
  static Future<void> disableAll() async {
    if (!supported) return;
    try {
      await _init();
      await NativeGeofenceManager.instance.removeAllGeofences();
    } catch (_) {}
  }
}
