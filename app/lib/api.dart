import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Cấu hình qua: flutter run --dart-define=API_URL=https://api.example.com
/// Android emulator gọi máy host qua 10.0.2.2.
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8080');

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => message;
}

class Api {
  String? token;
  String? refreshToken;

  /// Gọi mỗi khi cặp token đổi (đăng nhập / làm mới) để lưu vào bộ nhớ an toàn.
  Future<void> Function(String access, String refresh)? onTokens;

  /// Gọi khi máy chủ từ chối refresh token (hết hạn, bị thu hồi, hoặc phát hiện dùng lại) → phải đăng nhập lại.
  void Function()? onSessionExpired;

  final _client = http.Client();
  Future<bool>? _refreshing;

  Uri _u(String path) => Uri.parse('$apiUrl$path');

  Future<dynamic> _request(String method, String path, Object? body, String? bearer) async {
    final req = http.Request(method, _u(path))
      ..headers['content-type'] = 'application/json'
      ..headers.addAll({if (bearer != null) 'authorization': 'Bearer $bearer'});
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 15)));
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode >= 400) {
      Map<String, dynamic> j = {};
      try {
        j = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      var msg = (j['error'] as String?) ?? 'Lỗi ${res.statusCode}';
      if (res.statusCode == 429) {
        final mins = (((j['retry_after'] as num?) ?? 60) / 60).ceil();
        msg = 'Thử quá nhiều lần. Vui lòng đợi khoảng $mins phút rồi thử lại.';
      } else if (res.statusCode == 401 && path == '/v1/auth/login') {
        msg = 'Email hoặc mật khẩu không đúng.';
      }
      throw ApiException(res.statusCode, msg);
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Gửi yêu cầu có xác thực. Gặp 401 (access token hết hạn 15 phút) thì làm mới token một lần rồi gửi lại.
  Future<dynamic> _send(String method, String path, [Object? body]) async {
    try {
      return await _request(method, path, body, token);
    } on ApiException catch (e) {
      if (e.status == 401 && !path.startsWith('/v1/auth/') && refreshToken != null && await refresh()) {
        return _request(method, path, body, token);
      }
      rethrow;
    }
  }

  /// Làm mới token. Gộp các lời gọi đồng thời thành một (refresh token chỉ dùng được một lần: gọi song song
  /// sẽ bị máy chủ coi là dùng lại và thu hồi cả phiên). Trả false nếu không làm mới được;
  /// chỉ coi là hết phiên khi máy chủ trả 401 — lỗi mạng/máy chủ thì giữ nguyên phiên.
  Future<bool> refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _doRefresh() async {
    final rt = refreshToken;
    if (rt == null) return false;
    try {
      final res = await _request('POST', '/v1/auth/refresh', {'refresh_token': rt}, null) as Map<String, dynamic>;
      await setSession(res);
      return true;
    } on ApiException catch (e) {
      if (e.status == 401) onSessionExpired?.call();
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setSession(Map<String, dynamic> res) async {
    token = res['token'] as String;
    refreshToken = res['refresh_token'] as String;
    await onTokens?.call(token!, refreshToken!);
  }

  /// Hết hạn (hoặc sắp hết hạn trong 60 giây) → làm mới trước khi mở WebSocket (máy chủ đóng WS khi token hết hạn).
  Future<void> ensureFresh() async {
    final t = token;
    if (t == null || refreshToken == null) return;
    if (_secondsLeft(t) < 60) await refresh();
  }

  static int _secondsLeft(String jwt) {
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(jwt.split('.')[1])));
      final exp = (jsonDecode(payload) as Map<String, dynamic>)['exp'] as int;
      return exp - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    } catch (_) {
      return 0;
    }
  }

  /// Đăng xuất phía máy chủ (thu hồi phiên). Cố gắng hết sức: lỗi mạng không chặn việc đăng xuất cục bộ.
  Future<void> logoutRemote() async {
    final rt = refreshToken;
    if (rt == null) return;
    try {
      await _request('POST', '/v1/auth/logout', {'refresh_token': rt}, null).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Uri wsUri(String homeId) {
    final u = Uri.parse(apiUrl);
    return Uri(
      scheme: u.scheme == 'https' ? 'wss' : 'ws',
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: '/v1/homes/$homeId/ws',
      queryParameters: {'token': token},
    );
  }

  // auth
  Future<Map<String, dynamic>> login(String email, String password) async => await _send('POST', '/v1/auth/login', {'email': email, 'password': password});
  Future<Map<String, dynamic>> register(String email, String password, String name) async =>
      await _send('POST', '/v1/auth/register', {'email': email, 'password': password, 'name': name});

  /// Đăng nhập bằng ID token của Google/Apple. [nonce]: chuỗi gốc (Apple nhận bản sha256 của nó).
  Future<Map<String, dynamic>> ssoLogin(String provider, String idToken, {String? nonce, String? name, String? authorizationCode}) async => await _send(
    'POST',
    '/v1/auth/sso',
    {'authorization_code': ?authorizationCode, 'provider': provider, 'id_token': idToken, 'nonce': ?nonce, if (name != null && name.isNotEmpty) 'name': name},
  );

  /// Căn hộ sẽ bị xoá theo nếu xoá tài khoản: {homes: [{id, name, other_members}]}.
  Future<Map<String, dynamic>> accountDeletionPreview() async => await _send('GET', '/v1/me/deletion');

  /// Xoá vĩnh viễn tài khoản đang đăng nhập (và các căn hộ mà người này là quản lý duy nhất).
  Future<void> deleteAccount() => _send('DELETE', '/v1/me', {'confirm': 'DELETE'});

  /// Nhà cung cấp đăng nhập đang bật phía máy chủ: {password, google, apple}.
  Future<Map<String, dynamic>> authProviders() async => await _send('GET', '/v1/auth/providers');
  Future<Map<String, dynamic>> me() async => await _send('GET', '/v1/me');

  // ngữ cảnh (scene)
  Future<List<Scene>> scenes(String homeId) async =>
      ((await _send('GET', '/v1/homes/$homeId/scenes')) as List).map((e) => Scene.fromJson(Map<String, dynamic>.from(e))).toList();
  Future<void> createScene(String homeId, Map<String, dynamic> body) => _send('POST', '/v1/homes/$homeId/scenes', body);
  Future<void> updateScene(String id, Map<String, dynamic> body) => _send('PATCH', '/v1/scenes/$id', body);
  Future<void> deleteScene(String id) => _send('DELETE', '/v1/scenes/$id');

  /// Trả về {status, sent, total}.
  Future<Map<String, dynamic>> runScene(String id) async => Map<String, dynamic>.from(await _send('POST', '/v1/scenes/$id/run'));

  /// Tắt chế độ đang bật (ngừng cảnh báo cảm biến theo ngữ cảnh).
  Future<void> deactivateScene(String homeId) => _send('DELETE', '/v1/homes/$homeId/active-scene');
  Future<List<AppNotification>> notifications(String homeId) async =>
      ((await _send('GET', '/v1/homes/$homeId/notifications')) as List).map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e))).toList();

  Future<void> registerPushToken(String token, String platform) => _send('POST', '/v1/push/tokens', {'token': token, 'platform': platform});
  Future<void> deletePushToken(String token) => _send('DELETE', '/v1/push/tokens', {'token': token});

  Future<void> setHomeLocation(String homeId, double lat, double lng, int radius) =>
      _send('PUT', '/v1/homes/$homeId/location', {'lat': lat, 'lng': lng, 'radius_m': radius});
  Future<void> clearHomeLocation(String homeId) => _send('DELETE', '/v1/homes/$homeId/location');
  Future<void> reportPresence(String homeId, bool inside) => _send('PUT', '/v1/homes/$homeId/presence', {'inside': inside});

  Future<List<DeviceRule>> rules(String homeId) async =>
      ((await _send('GET', '/v1/homes/$homeId/rules')) as List).map((e) => DeviceRule.fromJson(Map<String, dynamic>.from(e))).toList();
  Future<void> createRule(String homeId, Map<String, dynamic> body) => _send('POST', '/v1/homes/$homeId/rules', body);
  Future<void> updateRule(String id, Map<String, dynamic> body) => _send('PATCH', '/v1/rules/$id', body);
  Future<void> deleteRule(String id) => _send('DELETE', '/v1/rules/$id');

  Future<List<Speaker>> speakers(String homeId) async =>
      ((await _send('GET', '/v1/homes/$homeId/speakers')) as List).map((e) => Speaker.fromJson(Map<String, dynamic>.from(e))).toList();
  Future<List<FoundSpeaker>> scanSpeakers(String homeId) async =>
      (((await _send('POST', '/v1/homes/$homeId/speakers/scan'))['devices']) as List).map((e) => FoundSpeaker.fromJson(Map<String, dynamic>.from(e))).toList();
  Future<void> addSpeaker(String homeId, FoundSpeaker f, String name) => _send('POST', '/v1/homes/$homeId/speakers', {
    'cast_id': f.castId,
    'name': name,
    'host': f.host,
    'port': f.port,
    if (f.gatewayId != null) 'gateway_id': f.gatewayId,
  });
  Future<void> renameSpeaker(String id, String name) => _send('PATCH', '/v1/speakers/$id', {'name': name});
  Future<void> deleteSpeaker(String id) => _send('DELETE', '/v1/speakers/$id');
  Future<void> testSpeaker(String id) => _send('POST', '/v1/speakers/$id/test');

  // tenant / home
  Future<void> createTenant(String name) => _send('POST', '/v1/tenants', {'name': name});
  Future<void> createHome(String tenantId, String name) => _send('POST', '/v1/tenants/$tenantId/homes', {'name': name});
  Future<List<Home>> homes() async => ((await _send('GET', '/v1/homes')) as List).map((e) => Home.fromJson(e)).toList();

  // rooms / devices
  Future<List<Room>> rooms(String homeId) async => ((await _send('GET', '/v1/homes/$homeId/rooms')) as List).map((e) => Room.fromJson(e)).toList();
  Future<void> createRoom(String homeId, String name, {String? icon}) => _send('POST', '/v1/homes/$homeId/rooms', {'name': name, 'icon': ?icon});
  Future<void> updateRoom(String roomId, {String? name, String? icon}) => _send('PATCH', '/v1/rooms/$roomId', {'name': ?name, 'icon': ?icon});
  Future<void> deleteRoom(String roomId) => _send('DELETE', '/v1/rooms/$roomId');
  Future<List<Device>> devices(String homeId) async => ((await _send('GET', '/v1/homes/$homeId/devices')) as List).map((e) => Device.fromJson(e)).toList();
  Future<void> updateDevice(String id, {String? name, String? roomId, bool clearRoom = false, Map<String, Channel>? channels}) => _send(
    'PATCH',
    '/v1/devices/$id',
    {'name': ?name, 'room_id': ?roomId, if (clearRoom) 'clear_room': true, if (channels != null) 'channels': channels.map((k, v) => MapEntry(k, v.toJson()))},
  );

  // ---- camera (addon go2rtc) ----
  Future<List<Camera>> cameras(String homeId) async =>
      ((await _send('GET', '/v1/homes/$homeId/cameras')) as List).map((e) => Camera.fromJson(Map<String, dynamic>.from(e))).toList();
  Future<List<FoundCamera>> scanCameras(String homeId) async =>
      (((await _send('POST', '/v1/homes/$homeId/cameras/scan'))['devices']) as List).map((e) => FoundCamera.fromJson(Map<String, dynamic>.from(e))).toList();
  Future<Camera> addCamera(String homeId, Map<String, dynamic> body) async =>
      Camera.fromJson(Map<String, dynamic>.from(await _send('POST', '/v1/homes/$homeId/cameras', body)));
  Future<void> updateCamera(String id, Map<String, dynamic> body) => _send('PATCH', '/v1/cameras/$id', body);
  Future<void> deleteCamera(String id) => _send('DELETE', '/v1/cameras/$id');

  /// Gửi SDP offer, nhận SDP answer của go2rtc (qua addon).
  Future<String> cameraWebrtc(String id, String sdp) async => (await _send('POST', '/v1/cameras/$id/webrtc', {'sdp': sdp}))['sdp'] as String;
  Future<void> cameraPtz(String id, {double pan = 0, double tilt = 0, double zoom = 0}) =>
      _send('POST', '/v1/cameras/$id/ptz', {'pan': pan, 'tilt': tilt, 'zoom': zoom});

  /// Ảnh JPEG hiện tại của camera (dự phòng khi WebRTC không nối được).
  Future<Uint8List> cameraSnapshot(String id, {int width = 640}) async {
    Future<http.Response> get() =>
        _client.get(_u('/v1/cameras/$id/snapshot?w=$width'), headers: {'authorization': 'Bearer $token'}).timeout(const Duration(seconds: 20));
    var res = await get();
    if (res.statusCode == 401 && await refresh()) res = await get();
    if (res.statusCode >= 400) {
      String msg = 'Lỗi ${res.statusCode}';
      try {
        msg = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['error'] ?? msg;
      } catch (_) {}
      throw ApiException(res.statusCode, msg);
    }
    return res.bodyBytes;
  }

  /// Mở (seconds > 0) / đóng (0) cửa sổ ghép thiết bị Zigbee mới; trả về số giây máy chủ đã áp dụng.
  Future<int> permitJoin(String homeId, int seconds) async =>
      ((await _send('POST', '/v1/homes/$homeId/zigbee/permit-join', {'seconds': seconds}))['seconds'] as num).toInt();
  /// Máy lọc nước Bluetooth quanh addon (mất ~10 giây).
  Future<List<Map<String, dynamic>>> scanPurifiers(String homeId) async =>
      [for (final e in (await _send('POST', '/v1/homes/$homeId/purifiers/scan'))['devices'] as List) Map<String, dynamic>.from(e)];
  Future<void> addPurifier(String homeId, Map<String, dynamic> body) => _send('POST', '/v1/homes/$homeId/purifiers', body);

  /// Gỡ thiết bị (hiện chỉ máy lọc nước Bluetooth).
  Future<void> deleteDevice(String deviceId) => _send('DELETE', '/v1/devices/$deviceId');
  Future<void> command(String deviceId, Map<String, dynamic> payload) => _send('POST', '/v1/devices/$deviceId/command', {'payload': payload});

  // Matter bridge (Google Home / Apple Home). Chỉ admin/owner; phản hồi chứa mã ghép nối nên không lưu cache.
  Future<MatterInfo> matterInfo(String homeId) async => MatterInfo.fromJson(Map<String, dynamic>.from(await _send('GET', '/v1/homes/$homeId/matter')));
  Future<MatterInfo> matterPairing(String homeId, bool open) async =>
      MatterInfo.fromJson(Map<String, dynamic>.from(await _send('POST', '/v1/homes/$homeId/matter/pairing', {'open': open})));
  Future<MatterInfo> matterRemoveFabric(String homeId, int index) async =>
      MatterInfo.fromJson(Map<String, dynamic>.from(await _send('DELETE', '/v1/homes/$homeId/matter/fabrics/$index')));

  // members
  Future<List<Member>> members(String homeId) async => ((await _send('GET', '/v1/homes/$homeId/members')) as List).map((e) => Member.fromJson(e)).toList();
  Future<void> removeMember(String homeId, String userId) => _send('DELETE', '/v1/homes/$homeId/members/$userId');
  Future<String> invite(String homeId, String role, {int? durationHours, DateTime? startsAt}) async => (await _send('POST', '/v1/homes/$homeId/invites', {
    'role': role,
    'duration_hours': ?durationHours,
    if (startsAt != null) 'starts_at': startsAt.toUtc().toIso8601String(),
  }))['token'];

  /// Can thiệp quyền khách thuê: 'grant_now' (cấp ngay) hoặc 'extend' (gia hạn `hours` giờ).
  Future<void> memberAction(String homeId, String userId, String action, {int? hours}) =>
      _send('PATCH', '/v1/homes/$homeId/members/$userId', {'action': action, 'hours': ?hours});

  /// Trả về {home_id, role, valid_from, valid_until} (hai trường sau chỉ có với khách thuê).
  Future<Map<String, dynamic>> acceptInvite(String token) async => Map<String, dynamic>.from(await _send('POST', '/v1/invites/accept', {'token': token}));
  Future<Map<String, dynamic>> gateways(String homeId) async => await _send('GET', '/v1/homes/$homeId/gateways');

  /// Trả về token của gateway — chỉ hiển thị MỘT lần.
  Future<String> createGateway(String homeId, String name) async => (await _send('POST', '/v1/homes/$homeId/gateways', {'name': name}))['token'];

  /// Thu hồi token cũ, cấp token mới (hiển thị một lần). Thiết bị/phòng được giữ nguyên.
  Future<String> rotateGateway(String gatewayId) async => (await _send('POST', '/v1/gateways/$gatewayId/rotate'))['token'];

  /// Xoá gateway; các thiết bị của nó bị xoá theo.
  Future<void> deleteGateway(String gatewayId) => _send('DELETE', '/v1/gateways/$gatewayId');

  /// URL WebSocket mà gateway (Pi) cần: http(s)://host -> ws(s)://host/gw/ws
  String get gatewayWsUrl => '${apiUrl.replaceFirst(RegExp(r'^http'), 'ws')}/gw/ws';
}
