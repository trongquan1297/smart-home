import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home/models.dart';

void main() {
  checkinTests();
  alertTests();
  test('fmtRemaining: ngày / giờ / phút', () {
    expect(fmtRemaining(const Duration(days: 2, hours: 3, minutes: 5)), '2 ngày 3 giờ');
    expect(fmtRemaining(const Duration(days: 1)), '1 ngày');
    expect(fmtRemaining(const Duration(hours: 5, minutes: 20)), '5 giờ 20 phút');
    expect(fmtRemaining(const Duration(hours: 3)), '3 giờ');
    expect(fmtRemaining(const Duration(minutes: 12, seconds: 40)), '12 phút');
    expect(fmtRemaining(const Duration(seconds: 30)), 'dưới 1 phút');
    expect(fmtRemaining(Duration.zero), '0 phút');
    expect(fmtRemaining(const Duration(minutes: -5)), '0 phút');
  });

  test('Home: khách thuê điều khiển được nhưng không chạy ngữ cảnh, không quản trị', () {
    Home h(String role) => Home.fromJson({'id': 'x', 'tenant_id': 't', 'name': 'n', 'role': role, 'access_until': role == 'renter' ? '2030-01-01T00:00:00Z' : null});
    final r = h('renter');
    expect(r.isRenter, true);
    expect(r.canControl, true);
    expect(r.canRunScenes, false);
    expect(r.isAdmin, false);
    expect(r.accessUntil, isNotNull);
    expect(h('guest').canControl, false);
    expect(h('member').canRunScenes, true);
    expect(h('owner').canRunScenes, true);
    expect(h('member').isRenter, false);
    expect(h('member').accessUntil, isNull);
  });

  test('Member: đọc trạng thái khách thuê', () {
    final m = Member.fromJson({
      'user_id': 'u', 'name': 'A', 'email': 'a@b.c', 'role': 'renter',
      'valid_from': '2026-11-13T09:00:00Z', 'valid_until': '2026-11-13T11:00:00Z', 'duration_hours': 2, 'status': 'active',
    });
    expect(m.isRenter, true);
    expect(m.durationHours, 2);
    expect(m.validUntil!.difference(m.validFrom!), const Duration(hours: 2));
    expect(Member.fromJson({'user_id': 'u', 'name': 'A', 'email': 'e', 'role': 'owner'}).validUntil, isNull);
  });
}

void checkinTests() {
  test('fmtCountdown: đồng hồ đếm ngược', () {
    expect(fmtCountdown(const Duration(hours: 2, minutes: 14, seconds: 55)), '02:14:55');
    expect(fmtCountdown(const Duration(seconds: 5)), '00:00:05');
    expect(fmtCountdown(const Duration(days: 1, hours: 2, minutes: 3, seconds: 4)), '1 ngày 02:03:04');
    expect(fmtCountdown(Duration.zero), '00:00:00');
    expect(fmtCountdown(const Duration(seconds: -9)), '00:00:00');
  });

  test('Home.isWaiting theo trạng thái máy chủ, không theo đồng hồ máy', () {
    Home h(String role, String? st) => Home.fromJson({
          'id': 'x', 'tenant_id': 't', 'name': 'n', 'role': role,
          'access_status': st, 'access_from': st == null ? null : '2030-01-01T00:00:00Z', 'access_until': st == null ? null : '2030-01-02T00:00:00Z',
        });
    expect(h('renter', 'scheduled').isWaiting, true);
    expect(h('renter', 'active').isWaiting, false);
    expect(h('member', null).isWaiting, false);
    expect(h('renter', 'scheduled').accessFrom, isNotNull);
  });
}

void alertTests() {
  test('Scene: đọc cảm biến cảnh báo và trạng thái đang bật', () {
    final s = Scene.fromJson({
      'id': 's', 'name': 'Đi vắng', 'icon': 'away', 'actions': [],
      'auto_enabled': false, 'auto_time': null, 'auto_days': [1, 2, 3],
      'alert_devices': ['d1', 'd2'], 'active': true,
    });
    expect(s.alertDevices, ['d1', 'd2']);
    expect(s.active, true);
    // máy chủ cũ không gửi trường mới → mặc định không cảnh báo, không đang bật
    final old = Scene.fromJson({'id': 's', 'name': 'x', 'icon': 'home', 'actions': [], 'auto_enabled': false, 'auto_days': [1]});
    expect(old.alertDevices, isEmpty);
    expect(old.active, false);
  });

  test('Device: nhận diện cảm biến hiện diện / cửa từ exposes', () {
    Device d(List exposes) => Device.fromJson({
          'id': 'x', 'name': 'n', 'room_id': null, 'kind': 'sensor', 'online': true, 'state': {}, 'exposes': exposes,
        });
    final door = d([{'type': 'binary', 'property': 'contact', 'access': 1}]);
    final occ = d([{'type': 'binary', 'property': 'occupancy', 'access': 1}, {'type': 'numeric', 'property': 'battery'}]);
    final sw = d([{'type': 'switch', 'features': [{'type': 'binary', 'property': 'state'}]}]);
    expect(door.hasDoor && !door.hasPresence && door.isAlertSensor, true);
    expect(occ.hasPresence && !occ.hasDoor && occ.isAlertSensor, true);
    expect(sw.isAlertSensor, false);
  });

  test('AppNotification.fromJson', () {
    final n = AppNotification.fromJson({'id': 7, 'kind': 'door_open', 'title': 'Cửa vừa mở', 'body': 'x', 'created_at': '2026-11-14T05:00:00Z'});
    expect(n.id, 7);
    expect(n.kind, 'door_open');
    expect(n.createdAt.toUtc().hour, 5);
  });
}
