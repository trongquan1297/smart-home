import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'models.dart';

class AppModel extends ChangeNotifier {
  final api = Api();
  final _storage = const FlutterSecureStorage();

  bool booting = true;
  bool get loggedIn => api.token != null;
  Map<String, dynamic>? me;

  List<Home> homes = [];
  Home? home;
  List<Room> rooms = [];
  List<Device> devices = [];
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
    if (remote) await api.logoutRemote(); // thu hồi phiên phía máy chủ (tối đa 5 giây, lỗi mạng bỏ qua)
    api.token = null;
    api.refreshToken = null;
    me = null;
    homes = [];
    home = null;
    rooms = [];
    devices = [];
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
    home = h;
    rooms = [];
    devices = [];
    gatewayOnline = false;
    notifyListeners();
    await reload();
    await api.ensureFresh();
    _openWs();
  }

  void leaveHome() {
    _closeWs();
    home = null;
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
    } catch (e) {
      error = e.toString();
    }
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
