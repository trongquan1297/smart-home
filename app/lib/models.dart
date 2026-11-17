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

  static ChannelType parse(String? id) => ChannelType.values.firstWhere((t) => t.id == id, orElse: () => ChannelType.other);
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
  final String role; // owner | admin | member | renter | guest
  /// Chỉ với khách thuê: thời điểm hết quyền truy cập.
  final DateTime? accessUntil;

  /// Chỉ với khách thuê: thời điểm bắt đầu có quyền (check-in) và trạng thái do máy chủ báo (scheduled | active).
  final DateTime? accessFrom;
  final String? accessStatus;

  /// Vị trí căn hộ cho geofence "rời nhà" (do quản trị đặt); null nếu chưa đặt.
  final double? geoLat, geoLng;
  final int geoRadius;
  Home({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.role,
    this.accessUntil,
    this.accessFrom,
    this.accessStatus,
    this.geoLat,
    this.geoLng,
    this.geoRadius = 150,
  });
  bool get hasLocation => geoLat != null && geoLng != null;

  factory Home.fromJson(Map<String, dynamic> j) => Home(
    id: j['id'],
    tenantId: j['tenant_id'],
    name: j['name'],
    role: j['role'],
    accessUntil: j['access_until'] == null ? null : DateTime.parse(j['access_until']).toLocal(),
    accessFrom: j['access_from'] == null ? null : DateTime.parse(j['access_from']).toLocal(),
    accessStatus: j['access_status'],
    geoLat: (j['geo_lat'] as num?)?.toDouble(),
    geoLng: (j['geo_lng'] as num?)?.toDouble(),
    geoRadius: (j['geo_radius_m'] as num?)?.toInt() ?? 150,
  );

  bool get canControl => role != 'guest';
  bool get isAdmin => role == 'admin' || role == 'owner';
  bool get isRenter => role == 'renter'; // khách thuê: chỉ bật/tắt, có thời hạn
  /// Khách thuê đã nhận mã nhưng chưa tới giờ check-in (theo máy chủ): xem được thẻ đếm ngược, chưa vào được căn hộ.
  bool get isWaiting => isRenter && accessStatus == 'scheduled';
  bool get canRunScenes => role == 'member' || isAdmin;
}

/// "13:05 13/11"
String fmtDateTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} ${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')}';

/// Đồng hồ đếm ngược: "02:14:55", hoặc "1 ngày 02:14:55" khi còn từ 24 giờ.
String fmtCountdown(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int n) => n.toString().padLeft(2, '0');
  final hms = '${two(d.inHours % 24)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  return d.inDays > 0 ? '${d.inDays} ngày $hms' : hms;
}

/// Khoảng thời gian còn lại, dạng "2 ngày 3 giờ", "5 giờ 20 phút", "12 phút".
String fmtRemaining(Duration d) {
  if (d.inSeconds <= 0) return '0 phút';
  if (d.inMinutes < 1) return 'dưới 1 phút';
  final days = d.inDays, hours = d.inHours % 24, mins = d.inMinutes % 60;
  if (days > 0) return hours > 0 ? '$days ngày $hours giờ' : '$days ngày';
  if (d.inHours > 0) return mins > 0 ? '${d.inHours} giờ $mins phút' : '${d.inHours} giờ';
  return '${d.inMinutes} phút';
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
  final String? vendor; // hãng (Aqara, Tuya, VSmart…) do Zigbee2MQTT báo
  final bool isCover; // rèm / cửa cuốn: state OPEN/CLOSE/STOP + position
  final bool hasPosition;
  final bool hasPresence; // cảm biến hiện diện (expose `occupancy`)
  final bool hasDoor; // cảm biến cửa (expose `contact`)
  final Map<String, String> units; // đơn vị theo thuộc tính, lấy từ exposes (vd temperature → °C)
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
    this.vendor,
    this.isCover = false,
    this.hasPosition = false,
    this.hasPresence = false,
    this.hasDoor = false,
    this.units = const {},
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
    vendor: j['vendor'],
    isCover: _hasType(j['exposes'], 'cover'),
    hasPosition: _hasCoverPosition(j['exposes']),
    hasPresence: _hasProperty(j['exposes'], 'occupancy'),
    hasDoor: _hasProperty(j['exposes'], 'contact'),
    units: _units(j['exposes']),
    channels: {
      for (final e in Map<String, dynamic>.from(j['channels'] ?? {}).entries)
        e.key: Channel(name: (e.value['name'] ?? '') as String, type: ChannelType.parse(e.value['type'])),
    },
  );

  static bool _hasType(dynamic exposes, String type) {
    var found = false;
    void walk(dynamic n) {
      if (n is List) {
        n.forEach(walk);
      } else if (n is Map) {
        if (n['type'] == type) found = true;
        walk(n['features']);
      }
    }

    walk(exposes);
    return found;
  }

  static bool _hasProperty(dynamic exposes, String name) {
    var found = false;
    void walk(dynamic n) {
      if (n is List) {
        n.forEach(walk);
      } else if (n is Map) {
        if (n['property'] == name) found = true;
        walk(n['features']);
      }
    }

    walk(exposes);
    return found;
  }

  /// Cảm biến có thể chọn làm nguồn cảnh báo trong một ngữ cảnh.
  bool get isAlertSensor => hasPresence || hasDoor;

  static bool _hasCoverPosition(dynamic exposes) {
    var found = false;
    void walk(dynamic n, bool inCover) {
      if (n is List) {
        for (final e in n) {
          walk(e, inCover);
        }
      } else if (n is Map) {
        final cover = inCover || n['type'] == 'cover';
        if (cover && n['property'] == 'position') found = true;
        walk(n['features'], cover);
      }
    }

    walk(exposes, false);
    return found;
  }

  /// Đơn vị của từng thuộc tính số (vd {'temperature': '°C', 'voltage': 'mV'}).
  static Map<String, String> _units(dynamic exposes) {
    final out = <String, String>{};
    void walk(dynamic n) {
      if (n is List) {
        n.forEach(walk);
      } else if (n is Map) {
        final p = n['property'], u = n['unit'];
        if (p is String && u is String) out[p] = u;
        walk(n['features']);
      }
    }

    walk(exposes);
    return out;
  }

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

  bool get isPlug {
    final d = (description ?? '').toLowerCase();
    return d.contains('plug') || d.contains('socket') || d.contains('outlet');
  }

  /// Tên mặc định của gang. Zigbee2MQTT đặt hậu tố theo endpoint: VSmart `state_1`, Tuya `state_l1`,
  /// Aqara/Tuya nhiều gang `state_left` / `state_right` / `state_center`.
  String defaultLabel(String key) {
    final m = RegExp(r'^state_(.+)$').firstMatch(key);
    if (m == null) return isPlug ? 'Ổ cắm' : 'Nguồn';
    final suf = m.group(1)!.toLowerCase();
    final n = RegExp(r'^l?(\d+)$').firstMatch(suf);
    if (n != null) return 'Gang ${n.group(1)}';
    return switch (suf) {
      'left' => 'Gang trái',
      'right' => 'Gang phải',
      'center' || 'middle' => 'Gang giữa',
      'top' => 'Gang trên',
      'bottom' => 'Gang dưới',
      _ => 'Gang $suf',
    };
  }

  /// Tên hiển thị của gang: tên người dùng đặt, nếu trống thì tên mặc định.
  String labelFor(String key) {
    final n = channels[key]?.name.trim() ?? '';
    return n.isNotEmpty ? n : defaultLabel(key);
  }

  ChannelType channelType(String key) => channels[key]?.type ?? (isPlug ? ChannelType.outlet : ChannelType.other);

  /// Loại nhận dạng của thiết bị, dịch từ mô tả model của Zigbee2MQTT.
  /// Loại thiết bị bằng tiếng Việt, suy từ mô tả model của Zigbee2MQTT (tiếng Anh, khác nhau theo hãng).
  String get typeLabel {
    final raw = description ?? '';
    final d = raw.toLowerCase();
    final gang = RegExp(r'(\d)\s*gang').firstMatch(d);
    if (isCover || d.contains('curtain') || d.contains('blind')) return 'Rèm / cửa cuốn';
    if (isPlug) return d.contains('monitoring') || state.containsKey('power') ? 'Ổ cắm đo điện' : 'Ổ cắm';
    if (gang != null) return 'Công tắc ${gang.group(1)} gang';
    if (d.contains('double rocker')) return 'Công tắc 2 gang';
    if (d.contains('temperature') && d.contains('humidity')) return 'Cảm biến nhiệt độ & độ ẩm';
    if (d.contains('water leak')) return 'Cảm biến rò nước';
    if (d.contains('smoke')) return 'Cảm biến khói';
    if (d.contains('door') || d.contains('window') || d.contains('contact')) return 'Cảm biến cửa';
    if (d.contains('occupancy') || d.contains('motion') || d.contains('presence')) return 'Cảm biến hiện diện';
    if (raw.isNotEmpty) return raw;
    return switch (kind) {
      'switch' => 'Công tắc',
      'light' => 'Đèn',
      'sensor' => 'Cảm biến',
      'cover' => 'Rèm / cửa cuốn',
      _ => 'Thiết bị',
    };
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
    // Số liệu đo theo tên thuộc tính chuẩn của Zigbee2MQTT (cùng một cách đọc cho Aqara, Tuya, VSmart…).
    String fmt(num v, int digits) {
      final t = v.toStringAsFixed(digits);
      return t.contains('.') ? t.replaceFirst(RegExp(r'\.?0+$'), '') : t;
    }

    void measure(String key, String label, IconData icon, {String? unit, int digits = 1}) {
      final v = state[key];
      if (v is! num) return;
      final u = units[key] ?? unit ?? '';
      out.add(Reading(label, u.isEmpty ? fmt(v, digits) : '${fmt(v, digits)} ${u == '%' ? '%' : u}', icon, false));
    }

    measure('temperature', 'Nhiệt độ', Icons.thermostat_rounded, unit: '°C');
    measure('humidity', 'Độ ẩm', Icons.water_drop_outlined, unit: '%', digits: 0);
    measure('pressure', 'Áp suất', Icons.speed_rounded, unit: 'hPa', digits: 0);
    measure('illuminance', 'Độ sáng', Icons.light_mode_outlined, unit: 'lx', digits: 0);
    measure('illuminance_lux', 'Độ sáng', Icons.light_mode_outlined, unit: 'lx', digits: 0);
    measure('power', 'Công suất', Icons.bolt_rounded, unit: 'W');
    measure('current', 'Dòng điện', Icons.electrical_services_rounded, unit: 'A', digits: 2);
    measure('energy', 'Điện năng', Icons.insights_rounded, unit: 'kWh', digits: 2);
    if (units['voltage'] == 'V') measure('voltage', 'Điện áp', Icons.power_rounded, unit: 'V', digits: 0); // mV = điện áp pin, bỏ qua
    final leak = state['water_leak'];
    if (leak is bool) {
      out.add(Reading('Rò nước', leak ? 'Có rò rỉ' : 'Khô ráo', leak ? Icons.water_damage_rounded : Icons.water_drop_outlined, leak));
    }
    final smoke = state['smoke'];
    if (smoke is bool) {
      out.add(Reading('Khói', smoke ? 'Có khói' : 'Bình thường', smoke ? Icons.local_fire_department_rounded : Icons.cloud_outlined, smoke));
    }
    final vib = state['vibration'];
    if (vib is bool) {
      out.add(Reading('Rung', vib ? 'Có rung' : 'Yên', vib ? Icons.vibration_rounded : Icons.do_not_disturb_on_outlined, vib));
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
  // Khách thuê: cửa sổ truy cập và trạng thái (scheduled | active | expired)
  final DateTime? validFrom, validUntil;
  final int? durationHours;
  final String? status;
  Member({required this.userId, required this.name, required this.email, required this.role, this.validFrom, this.validUntil, this.durationHours, this.status});
  factory Member.fromJson(Map<String, dynamic> j) => Member(
    userId: j['user_id'],
    name: j['name'],
    email: j['email'],
    role: j['role'],
    validFrom: j['valid_from'] == null ? null : DateTime.parse(j['valid_from']).toLocal(),
    validUntil: j['valid_until'] == null ? null : DateTime.parse(j['valid_until']).toLocal(),
    durationHours: j['duration_hours'],
    status: j['status'],
  );
  bool get isRenter => role == 'renter';
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

  factory SceneAction.fromJson(Map<String, dynamic> j) => SceneAction(j['device_id'], {
    for (final e in Map<String, dynamic>.from(j['payload'] ?? {}).entries)
      if (e.value is String) e.key: e.value as String,
  });
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
  final List<String> alertDevices; // cảm biến được báo khi ngữ cảnh này đang bật
  final bool active; // ngữ cảnh đang bật của căn hộ (chạy gần nhất)
  final bool autoLeave; // tự chạy khi người cuối cùng rời nhà

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
    this.alertDevices = const [],
    this.active = false,
    this.autoLeave = false,
  });

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
    id: j['id'],
    name: j['name'],
    icon: j['icon'] ?? 'home',
    actions: [for (final a in (j['actions'] as List? ?? [])) SceneAction.fromJson(Map<String, dynamic>.from(a))],
    autoEnabled: j['auto_enabled'] == true,
    autoTime: j['auto_time'],
    autoDays: [
      for (final d in (j['auto_days'] as List? ?? [1, 2, 3, 4, 5, 6, 7])) (d as num).toInt(),
    ],
    lastRunAt: j['last_run_at'] == null ? null : DateTime.parse(j['last_run_at']).toLocal(),
    lastStatus: j['last_status'],
    alertDevices: [for (final d in (j['alert_devices'] as List? ?? [])) d as String],
    active: j['active'] == true,
    autoLeave: j['auto_leave'] == true,
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

/// Một thông báo trong lịch sử của căn hộ (cảm biến hiện diện / cửa được kích hoạt).
class AppNotification {
  final int id;
  final String kind; // presence | door_open | scene_auto | scene_failed
  final String title;
  final String body;
  final DateTime createdAt;
  AppNotification({required this.id, required this.kind, required this.title, required this.body, required this.createdAt});
  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
    id: (j['id'] as num).toInt(),
    kind: j['kind'] ?? '',
    title: j['title'] ?? '',
    body: j['body'] ?? '',
    createdAt: DateTime.parse(j['created_at']).toLocal(),
  );
}

/// Luật tự động của một gang (biểu tượng tia sét): tự tắt sau khi bật, tự bật lại sau khi tắt, hoặc đồng kích hoạt theo gang khác.
class DeviceRule {
  final String id;
  final String deviceId;
  final String key; // gang áp dụng (state, state_1…)
  final String kind; // auto_off | auto_on | link
  final int? delaySeconds;
  final String? sourceDeviceId;
  final String? sourceKey;
  final String? sourceState; // ON | OFF
  final String? targetState; // ON | OFF
  final bool enabled;
  DeviceRule({
    required this.id,
    required this.deviceId,
    required this.key,
    required this.kind,
    this.delaySeconds,
    this.sourceDeviceId,
    this.sourceKey,
    this.sourceState,
    this.targetState,
    this.enabled = true,
  });

  factory DeviceRule.fromJson(Map<String, dynamic> j) => DeviceRule(
    id: j['id'],
    deviceId: j['device_id'],
    key: j['key'],
    kind: j['kind'],
    delaySeconds: (j['delay_s'] as num?)?.toInt(),
    sourceDeviceId: j['source_device_id'],
    sourceKey: j['source_key'],
    sourceState: j['source_state'],
    targetState: j['target_state'],
    enabled: j['enabled'] != false,
  );

  /// "30 giây", "5 phút", "1 giờ 30 phút".
  static String delayLabel(int s) {
    if (s < 60) return '$s giây';
    if (s < 3600) {
      final m = s ~/ 60, r = s % 60;
      return r == 0 ? '$m phút' : '$m phút $r giây';
    }
    final h = s ~/ 3600, m = (s % 3600) ~/ 60;
    return m == 0 ? '$h giờ' : '$h giờ $m phút';
  }
}
