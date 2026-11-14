import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'geofence_service.dart';
import 'notifier.dart';
import 'push_service.dart';
import 'models.dart';

class AppModel extends ChangeNotifier {
  final api = Api();
  final _storage = const FlutterSecureStorage();

  bool booting = true;
  bool get loggedIn => api.token != null;
  Map<String, dynamic>? me;

  List<Home> homes = [];
  Home? home;

  /// Căn hộ yêu thích: lưu trên thiết bị này theo từng tài khoản; mở app (hoặc đăng nhập) là vào thẳng căn hộ đó.
  String? favoriteHomeId;

  /// Thông báo hiện ở màn danh sách căn hộ (vd khách thuê hết quyền truy cập).
  String? notice;

  /// Do main.dart gắn: đóng mọi màn hình phụ đang mở trên Navigator.
  void Function()? onPopToRoot;
  List<Room> rooms = [];
  List<Device> devices = [];

  /// Ngữ cảnh của căn hộ (chỉ tải cho vai trò chạy được ngữ cảnh) — để hiện chế độ đang bật.
  List<Scene> scenes = [];

  /// Số cảnh báo chưa xem của căn hộ đang mở (chấm đỏ trên chuông). Mốc "đã xem" lưu theo (người dùng, căn hộ).
  int unreadAlerts = 0;
  bool notificationsOpen = false;

  /// Căn hộ đang mở có ngữ cảnh "rời nhà" nhưng máy này chưa cấp quyền vị trí "Luôn luôn" (hiện dải nhắc trên màn hình căn hộ).
  bool needsLocationPermission = false;
  String? _geoSig;
  Scene? get activeScene {
    for (final s in scenes) {
      if (s.active) return s;
    }
    return null;
  }

  bool gatewayOnline = false;
  String? error;

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _retry;
  bool _disposed = false;

  AppModel() {
    api.onTokens = (access, refresh) async {
      await _storage.write(key: 'token', value: access);
      await _storage.write(key: 'refresh_token', value: refresh);
    };
    // Refresh token bị máy chủ từ chối (hết hạn / thu hồi / nghi bị đánh cắp) → về màn hình đăng nhập.
    api.onSessionExpired = () => logout(remote: false);
  }

  Future<void> boot() async {
    try {
      api.token = await _storage.read(key: 'token');
      api.refreshToken = await _storage.read(key: 'refresh_token');
      if (api.refreshToken == null) api.token = null; // phiên cũ (trước khi có refresh token) → đăng nhập lại
      if (loggedIn) await _afterAuth();
    } on ApiException catch (e) {
      if (e.status == 401) {
        await logout(remote: false);
      } else {
        _dropMemorySession(); // lỗi máy chủ: giữ token trong bộ nhớ an toàn để lần mở sau thử lại
      }
    } catch (_) {
      _dropMemorySession(); // mất mạng khi mở app: không xoá phiên đã lưu
    }
    booting = false;
    notifyListeners();
  }

  void _dropMemorySession() {
    api.token = null;
    api.refreshToken = null;
  }

  Future<void> _afterAuth() async {
    me = await api.me();
    homes = await api.homes();
    await _openFavorite();
    unawaited(PushService.sync(api)); // đăng ký token đẩy nếu quyền thông báo đã được cấp
  }

  String get _favKey => 'favorite_home_${me?['id']}';

  bool isFavorite(Home h) => favoriteHomeId == h.id;

  /// Đặt (hoặc bỏ nếu `h` là căn hộ đang yêu thích) căn hộ yêu thích.
  Future<void> toggleFavorite(Home h) async {
    final next = isFavorite(h) ? null : h.id;
    favoriteHomeId = next;
    notifyListeners();
    try {
      if (next == null) {
        await _storage.delete(key: _favKey);
      } else {
        await _storage.write(key: _favKey, value: next);
      }
    } catch (_) {
      // không lưu được (vd bộ nhớ an toàn bị khoá): vẫn dùng được trong phiên này
    }
  }

  Future<void> _openFavorite() async {
    try {
      favoriteHomeId = await _storage.read(key: _favKey);
    } catch (_) {
      favoriteHomeId = null;
    }
    final id = favoriteHomeId;
    if (id == null) return;
    final matches = homes.where((h) => h.id == id);
    if (matches.isNotEmpty && matches.first.isWaiting) return; // khách thuê chưa tới giờ check-in: chưa mở được, giữ yêu thích
    if (matches.isEmpty) {
      // không còn quyền vào căn hộ đó (bị xoá khỏi căn hộ / căn hộ bị xoá) → bỏ yêu thích
      favoriteHomeId = null;
      try {
        await _storage.delete(key: _favKey);
      } catch (_) {}
      return;
    }
    await selectHome(matches.first);
  }

  Future<void> _auth(Future<Map<String, dynamic>> call) async {
    final res = await call;
    await api.setSession(res);
    await _afterAuth();
    notifyListeners();
  }

  Future<void> login(String email, String password) => _auth(api.login(email, password));
  Future<void> register(String email, String password, String name) => _auth(api.register(email, password, name));

  Future<void> logout({bool remote = true}) async {
    _closeWs();
    _geoSig = null;
    needsLocationPermission = false;
    await GeofenceService.disableAll(); // máy này không báo vị trí cho tài khoản khác
    if (remote) await PushService.unregister(api);
    if (remote) await api.logoutRemote(); // thu hồi phiên phía máy chủ (tối đa 5 giây, lỗi mạng bỏ qua)
    api.token = null;
    api.refreshToken = null;
    notice = null;
    favoriteHomeId = null; // lưu trữ giữ nguyên, lần đăng nhập sau của cùng tài khoản sẽ đọc lại
    me = null;
    unreadAlerts = 0;
    homes = [];
    home = null;
    rooms = [];
    devices = [];
    scenes = [];
    await _storage.delete(key: 'token');
    await _storage.delete(key: 'refresh_token');
    notifyListeners();
  }

  Future<void> refreshHomes() async {
    homes = await api.homes();
    notifyListeners();
  }

  /// Người dùng mới chưa có tenant: tạo khách hàng + căn hộ đầu tiên.
  Future<void> createFirstHome(String name) async {
    var tenants = (me?['tenants'] as List?) ?? [];
    if (tenants.isEmpty) {
      await api.createTenant('Gia đình ${me?['name'] ?? ''}'.trim());
      me = await api.me();
      tenants = me!['tenants'];
    }
    await api.createHome(tenants.first['id'], name);
    await refreshHomes();
  }

  Future<void> selectHome(Home h) async {
    if (h.isWaiting) return; // chưa tới giờ check-in: máy chủ sẽ từ chối mọi yêu cầu vào căn hộ này
    home = h;
    rooms = [];
    devices = [];
    gatewayOnline = false;
    notifyListeners();
    await reload();
    await api.ensureFresh();
    _openWs();
  }

  /// Quyền truy cập căn hộ đang mở vừa bị thu hồi / hết hạn: thoát về danh sách ngay và báo cho người dùng.
  void accessEnded() {
    final name = home?.name ?? 'căn hộ';
    onPopToRoot?.call();
    leaveHome();
    notice = 'Quyền truy cập "$name" đã kết thúc.';
    notifyListeners();
    refreshHomes().catchError((_) {});
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  void leaveHome() {
    _closeWs();
    home = null;
    scenes = [];
    unreadAlerts = 0;
    notifyListeners();
  }

  Future<void> reload() async {
    final h = home;
    if (h == null) return;
    try {
      final r = await Future.wait([api.rooms(h.id), api.devices(h.id)]);
      rooms = r[0] as List<Room>;
      devices = r[1] as List<Device>;
      error = null;
      await _loadScenes();
      await _loadUnread();
      unawaited(refreshGeofence());
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  String get _seenKey => 'notif_seen_${me?['id']}_${home?.id}';

  /// Đếm thông báo mới hơn mốc đã xem. Lần đầu (chưa có mốc) lấy hiện tại làm mốc để không báo cả lịch sử cũ.
  Future<void> _loadUnread() async {
    final h = home;
    if (h == null || !h.canRunScenes) {
      unreadAlerts = 0;
      return;
    }
    try {
      final key = _seenKey;
      final seen = DateTime.tryParse(await _storage.read(key: key) ?? '');
      if (seen == null) {
        await _storage.write(key: key, value: DateTime.now().toUtc().toIso8601String());
        unreadAlerts = 0;
        return;
      }
      final list = await api.notifications(h.id);
      unreadAlerts = list.where((n) => n.createdAt.isAfter(seen)).length;
    } catch (_) {
      // giữ số cũ nếu lỗi mạng thoáng qua
    }
  }

  /// Người dùng đã xem danh sách thông báo (`upTo` = thông báo mới nhất đã hiển thị).
  Future<void> markNotificationsSeen([DateTime? upTo]) async {
    unreadAlerts = 0;
    notifyListeners();
    try {
      await _storage.write(key: _seenKey, value: (upTo ?? DateTime.now()).toUtc().toIso8601String());
    } catch (_) {}
  }

  Future<void> _loadScenes() async {
    final h = home;
    if (h == null || !h.canRunScenes) {
      scenes = [];
      return;
    }
    try {
      scenes = await api.scenes(h.id);
    } catch (_) {
      // giữ danh sách cũ nếu lỗi mạng thoáng qua
    }
  }

  /// Đăng ký/gỡ geofence của căn hộ đang mở theo cấu hình hiện tại: chỉ khi căn hộ đã có vị trí và có ngữ cảnh "rời nhà".
  /// Chỉ làm lại khi cấu hình đổi (hoặc `force`), tránh đăng ký lại mỗi lần tải.
  Future<void> refreshGeofence({bool force = false}) async {
    final h = home;
    if (h == null || !GeofenceService.supported) return;
    final wanted = h.canRunScenes && h.hasLocation && scenes.any((s) => s.autoLeave);
    final sig = '${h.id}|$wanted|${h.geoLat}|${h.geoLng}|${h.geoRadius}';
    if (!force && sig == _geoSig) return;
    _geoSig = sig;
    if (!wanted) {
      needsLocationPermission = false;
      await GeofenceService.disable(h);
    } else {
      final ok = await GeofenceService.enable(api, h);
      needsLocationPermission = !ok && !await GeofenceService.hasAlways();
      if (!ok) _geoSig = null; // thử lại ở lần tải sau
    }
    notifyListeners();
  }

  /// Người dùng bấm vào dải nhắc: xin quyền "Luôn luôn" rồi đăng ký geofence.
  Future<void> enableLocationTracking() async {
    await GeofenceService.requestAlways();
    await refreshGeofence(force: true);
  }

  /// Nạp lại danh sách ngữ cảnh sau khi tạo/sửa/xoá (cập nhật chip "đang bật" và geofence).
  Future<void> reloadScenes() async {
    await _loadScenes();
    notifyListeners();
    unawaited(refreshGeofence());
  }

  /// Đặt vị trí căn hộ (quản trị) rồi nạp lại thông tin căn hộ.
  Future<void> setHomeLocation(double lat, double lng, int radius) async {
    final h = home;
    if (h == null) return;
    await api.setHomeLocation(h.id, lat, lng, radius);
    homes = await api.homes();
    home = homes.firstWhere((x) => x.id == h.id, orElse: () => h);
    notifyListeners();
    unawaited(refreshGeofence());
  }

  /// Chạy một ngữ cảnh (thành ngữ cảnh đang bật) rồi nạp lại danh sách để cập nhật trạng thái "đang bật".
  Future<Map<String, dynamic>> runScene(Scene s) async {
    final r = await api.runScene(s.id);
    await _loadScenes();
    notifyListeners();
    return r;
  }

  /// Tắt chế độ đang bật (ngừng cảnh báo cảm biến).
  Future<void> disarm() async {
    final h = home;
    if (h == null) return;
    await api.deactivateScene(h.id);
    await _loadScenes();
    notifyListeners();
  }

  Future<void> send(Device d, Map<String, dynamic> payload) async {
    try {
      await api.command(d.id, payload);
      error = null;
    } catch (e) {
      error = e.toString(); // vd "gateway offline"
      notifyListeners();
    }
    // Trạng thái mới đến qua WebSocket khi thiết bị xác nhận (không lạc quan hoá để tránh hiển thị sai).
  }

  // ---- realtime ----
  void _openWs() {
    _closeWs();
    final h = home;
    if (h == null || _disposed) return;
    final ch = WebSocketChannel.connect(api.wsUri(h.id));
    _ws = ch;
    _wsSub = ch.stream.listen(_onWs, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
  }

  void _closeWs() {
    _retry?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    _ws = null;
    _wsSub = null;
  }

  void _scheduleReconnect() {
    if (_disposed || home == null) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), () async {
      await api.ensureFresh(); // máy chủ đóng WS khi access token hết hạn → làm mới trước khi nối lại
      if (!loggedIn || home == null) return;
      await reload(); // bù các sự kiện đã lỡ khi mất kết nối
      await api.ensureFresh();
      _openWs();
    });
  }

  void _onWs(dynamic raw) {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['type']) {
      case 'gateway':
        gatewayOnline = m['online'] == true;
      case 'device_state':
        for (final d in devices) {
          if (d.id == m['device_id']) d.state = Map<String, dynamic>.from(m['state']);
        }
      case 'device_online':
        for (final d in devices) {
          if (d.id == m['device_id']) d.online = m['online'] == true;
        }
      case 'devices_changed':
        reload();
        return;
      case 'scene_active':
        _loadScenes().then((_) => notifyListeners());
        return;
      case 'alert':
        // Cảnh báo cảm biến: hiện thông báo trên thiết bị (máy chủ chỉ gửi cho vai trò từ thành viên trở lên).
        if (notificationsOpen) {
          markNotificationsSeen();
        } else {
          unreadAlerts++;
        }
        Notifier.show(
          ((m['id'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch) & 0x7fffffff,
          (m['title'] as String?) ?? 'Cảnh báo',
          (m['body'] as String?) ?? '',
        );
        return;
      case 'access_revoked':
        accessEnded();
        return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _closeWs();
    super.dispose();
  }
}
