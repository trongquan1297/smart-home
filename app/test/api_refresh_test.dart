// Chạy: flutter test --dart-define=API_URL=http://127.0.0.1:18080 test/api_refresh_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/api.dart';

/// Máy chủ giả: /v1/me chỉ nhận access token "good-N" hiện hành; /v1/auth/refresh xoay vòng token.
class FakeServer {
  late HttpServer srv;
  String validAccess = 'old-access';
  String validRefresh = 'rt-1';
  int refreshCalls = 0;
  int meCalls = 0;
  int refreshStatus = 200; // ép trạng thái refresh để thử 401 / 500
  bool dropRefresh = false; // mô phỏng mất mạng giữa chừng

  Future<void> start() async {
    srv = await HttpServer.bind('127.0.0.1', 18080);
    srv.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      Future<void> reply(int code, Object o) async {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(o));
        await req.response.close();
      }

      if (req.uri.path == '/v1/auth/refresh') {
        refreshCalls++;
        await Future.delayed(const Duration(milliseconds: 50)); // để các lời gọi song song kịp chồng lên nhau
        if (dropRefresh) return req.response.detachSocket().then((s) => s.destroy());
        final rt = (jsonDecode(body) as Map)['refresh_token'];
        if (refreshStatus != 200) return reply(refreshStatus, {'error': 'x'});
        if (rt != validRefresh) return reply(401, {'error': 'unauthorized'}); // dùng lại token cũ = bị từ chối
        validAccess = 'access-$refreshCalls';
        validRefresh = 'rt-${refreshCalls + 1}';
        return reply(200, {'token': validAccess, 'refresh_token': validRefresh, 'expires_in': 900, 'user': {}});
      }
      if (req.uri.path == '/v1/me') {
        meCalls++;
        final auth = req.headers.value('authorization');
        return auth == 'Bearer $validAccess' ? reply(200, {'ok': true}) : reply(401, {'error': 'unauthorized'});
      }
      if (req.uri.path == '/v1/auth/login') return reply(401, {'error': 'unauthorized'});
      if (req.uri.path == '/v1/auth/logout') return reply(204, {});
      reply(404, {});
    });
  }

  Future<void> stop() => srv.close(force: true);
}

void main() {
  late FakeServer s;
  late Api api;
  late List<String> saved;
  var expired = 0;

  setUp(() async {
    s = FakeServer();
    await s.start();
    expired = 0;
    saved = [];
    api = Api()
      ..token = 'old-access'
      ..refreshToken = 'rt-1'
      ..onTokens = (a, r) async {
        saved.add('$a|$r');
      }
      ..onSessionExpired = () => expired++;
  });
  tearDown(() => s.stop());

  test('access token hết hạn: tự làm mới rồi gửi lại, lưu cặp mới', () async {
    s.validAccess = 'something-else'; // token cũ không còn hợp lệ
    expect((await api.me())['ok'], true);
    expect(s.refreshCalls, 1);
    expect(api.token, 'access-1');
    expect(api.refreshToken, 'rt-2');
    expect(saved, ['access-1|rt-2']);
    expect(s.meCalls, 2); // lần 401 + lần thử lại
  });

  test('nhiều yêu cầu song song cùng gặp 401 chỉ làm mới MỘT lần (không bị coi là dùng lại)', () async {
    s.validAccess = 'something-else';
    final r = await Future.wait([api.me(), api.me(), api.me(), api.me()]);
    expect(r.every((e) => e['ok'] == true), true);
    expect(s.refreshCalls, 1);
    expect(expired, 0);
  });

  test('refresh bị 401 → báo hết phiên và ném lỗi 401', () async {
    s.validAccess = 'something-else';
    s.validRefresh = 'rt-khác'; // máy chủ không nhận refresh token đang giữ
    await expectLater(api.me(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
    expect(expired, 1);
  });

  test('máy chủ lỗi 500 khi refresh → KHÔNG đăng xuất, giữ phiên', () async {
    s.validAccess = 'something-else';
    s.refreshStatus = 500;
    await expectLater(api.me(), throwsA(isA<ApiException>()));
    expect(expired, 0);
    expect(api.refreshToken, 'rt-1');
  });

  test('mất mạng khi refresh → KHÔNG đăng xuất, giữ phiên', () async {
    s.validAccess = 'something-else';
    s.dropRefresh = true;
    await expectLater(api.me(), throwsA(anything));
    expect(expired, 0);
    expect(api.refreshToken, 'rt-1');
  });

  test('ensureFresh: token còn hạn lâu thì không gọi refresh; sắp hết hạn thì làm mới', () async {
    String jwt(int secs) {
      final p = base64Url.encode(utf8.encode(jsonEncode({'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + secs})));
      return 'h.$p.s';
    }

    api.token = jwt(600);
    await api.ensureFresh();
    expect(s.refreshCalls, 0);
    api.token = jwt(20);
    await api.ensureFresh();
    expect(s.refreshCalls, 1);
    expect(api.token, 'access-1');
  });

  test('đăng nhập sai: thông báo tiếng Việt, không thử refresh', () async {
    await expectLater(api.login('a@b.c', 'x'), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('không đúng'))));
    expect(s.refreshCalls, 0);
  });

  test('logoutRemote không ném lỗi dù không có mạng', () async {
    await s.stop();
    await api.logoutRemote();
    s = FakeServer();
    await s.start(); // để tearDown dọn được
  });
}
