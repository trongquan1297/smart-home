import 'package:flutter/material.dart';

/// Loại tải mà một gang/công tắc điều khiển. `id` trùng giá trị backend chấp nhận.
enum ChannelType {
  light('light', 'Đèn', Icons.lightbulb),
  fan('fan', 'Quạt', Icons.mode_fan_off),
  outlet('outlet', 'Ổ cắm', Icons.power),
  airConditioner('air_conditioner', 'Điều hòa', Icons.ac_unit),
  waterHeater('water_heater', 'Bình nóng lạnh', Icons.hot_tub),
  other('other', 'Khác', Icons.toggle_on);

  final String id;
  final String label;
  final IconData icon;
  const ChannelType(this.id, this.label, this.icon);

  static ChannelType parse(String? id) =>
      ChannelType.values.firstWhere((t) => t.id == id, orElse: () => ChannelType.other);
}

class Reading {
  final String label;
  final String value;
  final IconData icon;
  final bool alert;
  const Reading(this.label, this.value, this.icon, this.alert);
}

class Channel {
  final String name; // rỗng = dùng tên mặc định
  final ChannelType type;
  const Channel({this.name = '', this.type = ChannelType.other});

  Map<String, dynamic> toJson() => {'name': name, 'type': type.id};
}

class Home {
  final String id;
  final String tenantId;
  final String name;
  final String role; // owner | admin | member | guest
  Home({required this.id, required this.tenantId, required this.name, required this.role});

  factory Home.fromJson(Map<String, dynamic> j) =>
      Home(id: j['id'], tenantId: j['tenant_id'], name: j['name'], role: j['role']);

  bool get canControl => role != 'guest';
  bool get isAdmin => role == 'admin' || role == 'owner';
}

/// Loại phòng → icon. `id` trùng giá trị backend chấp nhận.
enum RoomKind {
  living('living', 'Phòng khách', Icons.weekend_rounded),
  bedroom('bedroom', 'Phòng ngủ', Icons.bed_rounded),
  kitchen('kitchen', 'Bếp', Icons.countertops_rounded),
  bathroom('bathroom', 'Vệ sinh', Icons.bathtub_rounded),
  dining('dining', 'Phòng ăn', Icons.restaurant_rounded),
  office('office', 'Làm việc', Icons.desk_rounded),
  balcony('balcony', 'Ban công', Icons.deck_rounded),
  garage('garage', 'Gara', Icons.garage_rounded),
  kids('kids', 'Phòng bé', Icons.child_care_rounded),
  laundry('laundry', 'Giặt phơi', Icons.local_laundry_service_rounded),
  hallway('hallway', 'Hành lang', Icons.stairs_rounded),
  other('other', 'Khác', Icons.meeting_room_rounded);

  final String id;
  final String label;
  final IconData icon;
  const RoomKind(this.id, this.label, this.icon);

  static RoomKind? parse(String? id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }

  /// Gợi ý loại phòng theo tên (bỏ dấu, không phân biệt hoa thường) khi người dùng chưa chọn icon.
  static RoomKind guess(String name) {
    final n = ' ${_fold(name).trim()} '; // so khớp theo TỪ nguyên vẹn, tránh "ban cong" dính "an"
    bool has(List<String> ws) => ws.any((w) => n.contains(' $w '));
    if (has(['khach', 'living'])) return living;
    if (has(['ngu', 'bedroom'])) return bedroom;
    if (has(['bep', 'kitchen'])) return kitchen;
    if (has(['ve sinh', 'tam', 'wc', 'toilet', 'bath'])) return bathroom;
    if (has(['an', 'dining'])) return dining;
    if (has(['lam viec', 'office', 'study', 'hoc'])) return office;
    if (has(['ban cong', 'san', 'balcony', 'lo gia'])) return balcony;
    if (has(['gara', 'garage', 'xe'])) return garage;
    if (has(['be', 'tre', 'kid', 'kids'])) return kids;
    if (has(['giat', 'phoi', 'laundry'])) return laundry;
    if (has(['hanh lang', 'cau thang', 'sanh', 'hall'])) return hallway;
    return other;
  }

  static String _fold(String s) {
    const from = 'àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ';
    const to = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
    final b = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      final i = from.indexOf(c);
      b.write(i >= 0 ? to[i] : c);
    }
    return b.toString();
  }
}

class Room {
  final String id;
  final String name;
  final String? icon;
  Room({required this.id, required this.name, this.icon});
  factory Room.fromJson(Map<String, dynamic> j) => Room(id: j['id'], name: j['name'], icon: j['icon']);

  /// Loại phòng hiệu lực: người dùng đã chọn, hoặc gợi ý theo tên.
  RoomKind get kind => RoomKind.parse(icon) ?? RoomKind.guess(name);
}

class Device {
  final String id;
  String name;
  String? roomId;
  final String kind;
  bool online;
  Map<String, dynamic> state;
  final List<String> switchKeys; // vd: ['state_1','state_2'] hoặc ['state']
  final String? description; // mô tả model do Zigbee2MQTT báo, vd "Wall switch 3 gang"
  final String? model;
  Map<String, Channel> channels;

  Device({
    required this.id,
    required this.name,
    required this.roomId,
    required this.kind,
    required this.online,
    required this.state,
    required this.switchKeys,
    this.description,
    this.model,
    this.channels = const {},
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'],
        name: j['name'],
        roomId: j['room_id'],
        kind: j['kind'],
        online: j['online'] ?? false,
        state: Map<String, dynamic>.from(j['state'] ?? {}),
        switchKeys: _stateKeys(j['exposes']),
        description: j['description'],
        model: j['model'],
        channels: {
          for (final e in Map<String, dynamic>.from(j['channels'] ?? {}).entries)
            e.key: Channel(name: (e.value['name'] ?? '') as String, type: ChannelType.parse(e.value['type'])),
        },
      );

  /// Duyệt cây `exposes` của Zigbee2MQTT, lấy các thuộc tính binary ON/OFF tên `state*`.
  static List<String> _stateKeys(dynamic exposes) {
    final keys = <String>[];
    void walk(dynamic n) {
      if (n is List) {
        n.forEach(walk);
      } else if (n is Map) {
        final p = n['property'];
        if (n['type'] == 'binary' && p is String && p.startsWith('state')) keys.add(p);
        walk(n['features']);
      }
    }

    walk(exposes);
    keys.sort();
    return keys;
  }

  bool isOn(String key) => state[key] == 'ON';

  /// Tên mặc định của gang: state_1 / state_l1 -> "Gang 1" (VSmart dùng state_1..state_N).
  String defaultLabel(String key) {
    final m = RegExp(r'_l?(\d+)$').firstMatch(key);
    return m == null ? 'Nguồn' : 'Gang ${m.group(1)}';
  }

  /// Tên hiển thị của gang: tên người dùng đặt, nếu trống thì tên mặc định.
  String labelFor(String key) {
    final n = channels[key]?.name.trim() ?? '';
    return n.isNotEmpty ? n : defaultLabel(key);
  }

  ChannelType channelType(String key) => channels[key]?.type ?? ChannelType.other;

  /// Loại nhận dạng của thiết bị, dịch từ mô tả model của Zigbee2MQTT.
  String get typeLabel {
    final d = description ?? '';
    final gang = RegExp(r'^Wall switch (\d) gang$').firstMatch(d);
    if (gang != null) return 'Công tắc ${gang.group(1)} gang';
    switch (d) {
      case 'Door/window sensor':
        return 'Cảm biến cửa';
      case 'Occupancy sensor':
        return 'Cảm biến hiện diện';
    }
    if (d.isNotEmpty) return d;
    return switch (kind) { 'switch' => 'Công tắc', 'light' => 'Đèn', 'sensor' => 'Cảm biến', _ => 'Thiết bị' };
  }

  bool get isSensor => kind == 'sensor';

  /// Số liệu cảm biến hiển thị được (chỉ những thuộc tính thiết bị đã báo).
  /// Quy ước Zigbee2MQTT: contact=true là đóng, false là mở; occupancy=true là có người.
  /// `alert` = trạng thái cần chú ý (cửa mở, có người, bị tác động, pin yếu).
  List<Reading> get readings {
    final out = <Reading>[];
    final c = state['contact'];
    if (c is bool) {
      out.add(Reading('Cửa', c ? 'Đóng' : 'Mở', c ? Icons.door_front_door_outlined : Icons.meeting_room_outlined, !c));
    }
    final o = state['occupancy'];
    if (o is bool) {
      out.add(Reading('Hiện diện', o ? 'Có người' : 'Không có người', o ? Icons.directions_walk : Icons.person_off_outlined, o));
    }
    final t = state['tamper'];
    if (t is bool) {
      out.add(Reading('Chống tháo', t ? 'Bị tác động' : 'Bình thường', t ? Icons.warning_amber_rounded : Icons.shield_outlined, t));
    }
    final b = state['battery'];
    final low = state['battery_low'];
    if (b is num) {
      out.add(Reading('Pin', '${b.round()}%', b < 20 ? Icons.battery_alert : Icons.battery_full, b < 20));
    } else if (low is bool) {
      out.add(Reading('Pin', low ? 'Sắp hết' : 'Ổn', low ? Icons.battery_alert : Icons.battery_full, low));
    }
    return out;
  }
}

class Member {
  final String userId;
  final String name;
  final String email;
  final String role;
  Member({required this.userId, required this.name, required this.email, required this.role});
  factory Member.fromJson(Map<String, dynamic> j) =>
      Member(userId: j['user_id'], name: j['name'], email: j['email'], role: j['role']);
}

/// Ứng dụng/hub Matter đã ghép với bridge (Apple Home, Google Home, ...).
class MatterFabric {
  final int index;
  final String label;
  final String vendor;
  const MatterFabric({required this.index, required this.label, required this.vendor});
  factory MatterFabric.fromJson(Map<String, dynamic> j) =>
      MatterFabric(index: (j['index'] as num).toInt(), label: (j['label'] ?? '') as String, vendor: (j['vendor'] ?? '') as String);
}

/// Trạng thái Matter bridge của căn hộ. `qr`/`manualCode` chỉ có khi đang cho phép ghép nối.
class MatterInfo {
  final bool available; // false = bridge chưa được bật trên Pi
  final bool online;
  final bool commissioned;
  final bool pairingOpen;
  final String? qr;
  final String? manualCode;
  final List<MatterFabric> fabrics;
  const MatterInfo({
    required this.available,
    this.online = false,
    this.commissioned = false,
    this.pairingOpen = false,
    this.qr,
    this.manualCode,
    this.fabrics = const [],
  });

  factory MatterInfo.fromJson(Map<String, dynamic> j) => MatterInfo(
        available: j['available'] == true,
        online: j['online'] == true,
        commissioned: j['commissioned'] == true,
        pairingOpen: j['pairing_open'] == true,
        qr: j['qr'] as String?,
        manualCode: j['manual_code'] as String?,
        fabrics: [for (final f in (j['fabrics'] as List? ?? [])) MatterFabric.fromJson(Map<String, dynamic>.from(f))],
      );

  /// Mã thủ công 11 số hiển thị dạng 4-3-4 như các Home app.
  String? get manualCodeFormatted {
    final m = manualCode;
    if (m == null) return null;
    return m.length == 11 ? '${m.substring(0, 4)}-${m.substring(4, 7)}-${m.substring(7)}' : m;
  }
}

/// Biểu tượng của ngữ cảnh (khớp SCENE_ICONS ở backend).
enum SceneKind {
  home('home', 'Về nhà', Icons.home_rounded),
  bed('bed', 'Đi ngủ', Icons.bedtime_rounded),
  sun('sun', 'Buổi sáng', Icons.wb_sunny_rounded),
  moon('moon', 'Buổi tối', Icons.nights_stay_rounded),
  away('away', 'Đi vắng', Icons.directions_walk_rounded),
  movie('movie', 'Xem phim', Icons.movie_rounded),
  party('party', 'Tiệc', Icons.celebration_rounded),
  work('work', 'Làm việc', Icons.laptop_mac_rounded),
  eco('eco', 'Tiết kiệm', Icons.eco_rounded),
  lock('lock', 'An ninh', Icons.lock_rounded);

  final String id;
  final String label;
  final IconData icon;
  const SceneKind(this.id, this.label, this.icon);

  static SceneKind parse(String? id) => values.firstWhere((k) => k.id == id, orElse: () => home);
}

/// Một hành động của ngữ cảnh: đặt các gang của một thiết bị về ON/OFF.
class SceneAction {
  final String deviceId;
  final Map<String, String> payload; // vd {'state_1': 'ON'}
  SceneAction(this.deviceId, this.payload);

  factory SceneAction.fromJson(Map<String, dynamic> j) => SceneAction(
        j['device_id'],
        {for (final e in Map<String, dynamic>.from(j['payload'] ?? {}).entries) if (e.value is String) e.key: e.value as String},
      );
  Map<String, dynamic> toJson() => {'device_id': deviceId, 'payload': payload};
}

class Scene {
  final String id;
  final String name;
  final String icon;
  final List<SceneAction> actions;
  final bool autoEnabled;
  final String? autoTime; // "HH:MM" theo múi giờ căn hộ
  final List<int> autoDays; // 1 = thứ Hai … 7 = Chủ nhật
  final DateTime? lastRunAt;
  final String? lastStatus; // running | ok | partial | failed | missed

  Scene({
    required this.id,
    required this.name,
    required this.icon,
    required this.actions,
    required this.autoEnabled,
    required this.autoTime,
    required this.autoDays,
    required this.lastRunAt,
    required this.lastStatus,
  });

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: j['id'],
        name: j['name'],
        icon: j['icon'] ?? 'home',
        actions: [for (final a in (j['actions'] as List? ?? [])) SceneAction.fromJson(Map<String, dynamic>.from(a))],
        autoEnabled: j['auto_enabled'] == true,
        autoTime: j['auto_time'],
        autoDays: [for (final d in (j['auto_days'] as List? ?? [1, 2, 3, 4, 5, 6, 7])) (d as num).toInt()],
        lastRunAt: j['last_run_at'] == null ? null : DateTime.parse(j['last_run_at']).toLocal(),
        lastStatus: j['last_status'],
      );

  SceneKind get kind => SceneKind.parse(icon);

  /// "Hằng ngày", "T2–T6", "T2, T4, T6"…
  static String daysLabel(List<int> days) {
    final d = ([...days]..sort());
    if (d.length == 7) return 'Hằng ngày';
    if (d.join() == '12345') return 'T2–T6';
    if (d.join() == '67') return 'T7, CN';
    const n = ['', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];
    return d.map((x) => n[x]).join(', ');
  }
}
