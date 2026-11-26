import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';
import '../geofence_service.dart';
import '../notifier.dart';
import '../push_service.dart';
import '../widgets/ui.dart';
import 'speak_picker.dart';

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Ngữ cảnh: nhóm thao tác bật/tắt nhiều thiết bị, chạy bằng một chạm hoặc tự kích hoạt vào khung giờ.
class ScenesScreen extends StatefulWidget {
  const ScenesScreen({super.key});
  @override
  State<ScenesScreen> createState() => _ScenesScreenState();
}

class _ScenesScreenState extends State<ScenesScreen> {
  List<Scene>? _scenes;
  String? _error;
  String? _running; // id ngữ cảnh đang chạy

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = context.read<AppModel>();
    try {
      final s = await m.api.scenes(m.home!.id);
      if (!mounted) return;
      setState(() {
        _scenes = s;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Scene s) async {
    final m = context.read<AppModel>();
    final msg = ScaffoldMessenger.of(context);
    setState(() => _running = s.id);
    try {
      final r = await m.api.runScene(s.id);
      final sent = r['sent'], total = r['total'];
      msg.showSnackBar(
        SnackBar(
          content: Text(
            r['status'] == 'running'
                ? 'Đang chạy lần lượt "${s.name}"…'
                : sent == total
                ? 'Đã chạy "${s.name}"'
                : 'Đã gửi $sent/$total lệnh của "${s.name}"',
          ),
        ),
      );
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(e.toString().contains('gateway offline') ? 'Bộ điều khiển trung tâm đang offline' : e.toString())));
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _edit(Scene? s) async {
    final saved = await showCenterSheet<bool>(
      context: context,
      builder: (_) => _SceneSheet(model: context.read<AppModel>(), scene: s),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final home = m.home!;
    final cs = Theme.of(context).colorScheme;
    final scenes = _scenes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ngữ cảnh'),
        actions: [
          if (home.isAdmin) IconButton(icon: const Icon(Icons.add_rounded), tooltip: 'Tạo ngữ cảnh', onPressed: () => _edit(null)),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
          children: [
            if (_error != null)
              Card(
                color: cs.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.error_outline, color: cs.onErrorContainer),
                  title: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
                  trailing: TextButton(onPressed: _load, child: const Text('Thử lại')),
                ),
              ),
            if (scenes == null && _error == null)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (scenes != null && scenes.isEmpty)
              EmptyState(
                icon: Icons.auto_awesome_rounded,
                colors: Vivid.scene,
                title: 'Chưa có ngữ cảnh',
                info: home.isAdmin
                    ? 'Ngữ cảnh bật/tắt nhiều thiết bị bằng một chạm, ví dụ "Đi ngủ" tắt hết đèn hay "Về nhà" bật đèn phòng khách. Có thể đặt giờ để tự chạy hoặc tự chạy khi mọi người rời nhà.'
                    : 'Quản trị căn hộ có thể tạo ngữ cảnh để bật/tắt nhiều thiết bị cùng lúc.',
              ),
            for (final s in scenes ?? const <Scene>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _SceneCard(
                  scene: s,
                  running: _running == s.id,
                  canRun: home.canControl,
                  onRun: () => _run(s),
                  onEdit: home.isAdmin ? () => _edit(s) : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SceneCard extends StatelessWidget {
  final Scene scene;
  final bool running;
  final bool canRun;
  final VoidCallback onRun;
  final VoidCallback? onEdit;
  const _SceneCard({required this.scene, required this.running, required this.canRun, required this.onRun, required this.onEdit});

  String? get _statusText {
    final t = scene.lastRunAt;
    switch (scene.lastStatus) {
      case 'ok':
        return t == null ? 'Đã tự chạy' : 'Tự chạy lúc ${_hhmm(t)} ${t.day}/${t.month}';
      case 'partial':
        return 'Chạy một phần lúc ${t == null ? '' : _hhmm(t)}';
      case 'failed':
        return 'Lần tự chạy gần nhất thất bại';
      case 'missed':
        return 'Bỏ lỡ lần tự chạy gần nhất (bộ điều khiển offline)';
      case 'skipped':
        return 'Đến giờ nhưng chưa đủ điều kiện, đã bỏ qua';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bad = scene.lastStatus == 'failed' || scene.lastStatus == 'missed' || scene.lastStatus == 'partial';
    final status = _statusText;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              IconBadge(scene.kind.icon, colors: sceneColors(scene.kind.id), size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(scene.name, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        if (scene.active) ...[const SizedBox(width: 8), Pill(Icons.bolt_rounded, 'Đang bật', color: cs.primary)],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        Pill(Icons.toggle_on_rounded, '${scene.actions.length}'),
                        if (scene.stepDelayMs > 0) Pill(Icons.timelapse_rounded, 'Lần lượt ${Scene.delayLabel(scene.stepDelayMs)}'),
                        if (scene.autoEnabled && scene.autoTime != null)
                          Pill(Icons.schedule_rounded, '${scene.autoTime} · ${Scene.daysLabel(scene.autoDays)}', color: Vivid.schedule.first),
                        if (scene.autoLeave) Pill(Icons.directions_walk_rounded, 'Rời nhà', color: Vivid.leave.first),
                        if (scene.autoArrive) Pill(Icons.home_rounded, 'Về nhà', color: Vivid.leave.first),
                        if (scene.triggerSensors.isNotEmpty) Pill(Icons.sensors_rounded, '${scene.triggerSensors.length}', color: Vivid.link.first),
                        if (scene.requiresAll) Pill(Icons.join_inner_rounded, 'Tất cả điều kiện', color: Vivid.scene.first),
                        if (scene.alertDevices.isNotEmpty) Pill(Icons.notifications_active_rounded, '${scene.alertDevices.length}', color: Vivid.alert.first),
                        if (scene.speakerIds.isNotEmpty) Pill(Icons.record_voice_over_rounded, '${scene.speakerIds.length}', color: Vivid.speak.first),
                        if (status != null && scene.triggerCount > 0)
                          Pill(bad ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded, status, color: bad ? cs.error : null),
                      ],
                    ),
                  ],
                ),
              ),
              if (canRun)
                running
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      )
                    : IconButton.filledTonal(onPressed: onRun, icon: const Icon(Icons.play_arrow_rounded), tooltip: 'Chạy ngay'),
            ],
          ),
        ),
      ),
    );
  }
}

/// Trình soạn ngữ cảnh: tên, biểu tượng, hành động theo từng gang (giữ nguyên / bật / tắt), tự kích hoạt.
class _SceneSheet extends StatefulWidget {
  final AppModel model;
  final Scene? scene;
  const _SceneSheet({required this.model, this.scene});
  @override
  State<_SceneSheet> createState() => _SceneSheetState();
}

class _SceneSheetState extends State<_SceneSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.scene?.name ?? '');
  late SceneKind _kind = widget.scene?.kind ?? SceneKind.home;
  // deviceId -> (key -> 'ON'|'OFF'); thiếu key = giữ nguyên
  late final Map<String, Map<String, String>> _plan = {
    for (final a in widget.scene?.actions ?? <SceneAction>[]) a.deviceId: Map<String, String>.from(a.payload),
  };
  late final Set<String> _alerts = {...?widget.scene?.alertDevices}; // cảm biến được báo khi ngữ cảnh này đang bật
  late bool _auto = widget.scene?.autoEnabled ?? false;
  late bool _leave = widget.scene?.autoLeave ?? false; // tự chạy khi người cuối cùng rời nhà
  late bool _arrive = widget.scene?.autoArrive ?? false; // tự chạy khi người đầu tiên về nhà
  late TimeOfDay? _end = _parse(widget.scene?.autoTimeEnd); // kết thúc khung giờ; null = chỉ mốc giờ
  late final List<SceneSensorTrigger> _sensorTriggers = [...?widget.scene?.triggerSensors];
  late String _logic = widget.scene?.triggerLogic ?? 'any'; // any = HOẶC, all = VÀ
  late final Set<String> _speakers = {...?widget.scene?.speakerIds}; // loa Cast đọc khi ngữ cảnh TỰ chạy
  late final TextEditingController _speakText = TextEditingController(text: widget.scene?.speakText ?? '');
  late int _stepDelay = widget.scene?.stepDelayMs ?? 0; // ms giữa các gang khi chạy; 0 = cùng lúc
  late int _radius = widget.model.home?.geoRadius ?? 150;
  bool _locBusy = false;
  late TimeOfDay _time = _parse(widget.scene?.autoTime) ?? const TimeOfDay(hour: 18, minute: 0);
  late final Set<int> _days = {
    ...(widget.scene?.autoDays ?? [1, 2, 3, 4, 5, 6, 7]),
  };
  bool _busy = false;
  String? _error;

  bool get _editing => widget.scene != null;

  static TimeOfDay? _parse(String? s) {
    if (s == null) return null;
    final p = s.split(':');
    if (p.length != 2) return null;
    return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
  }

  static String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  String get _timeText => _hm(_time);

  int get _triggerCount => (_auto ? 1 : 0) + (_leave ? 1 : 0) + (_arrive ? 1 : 0) + _sensorTriggers.length;
  bool get _all => _logic == 'all' && _triggerCount > 1;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final actions = [
      for (final e in _plan.entries)
        if (e.value.isNotEmpty) SceneAction(e.key, e.value).toJson(),
    ];
    if (name.isEmpty) return setState(() => _error = 'Nhập tên ngữ cảnh');
    if (actions.isEmpty) return setState(() => _error = 'Chọn ít nhất một thiết bị để bật hoặc tắt');
    if (_auto && _days.isEmpty) return setState(() => _error = 'Chọn ít nhất một ngày trong tuần');
    if ((_leave || _arrive) && widget.model.home?.hasLocation != true) {
      return setState(() => _error = 'Hãy đặt vị trí căn hộ để dùng điều kiện rời nhà / về nhà');
    }
    if (_all && _leave && _arrive) return setState(() => _error = 'Không thể yêu cầu cùng lúc "rời nhà" và "về nhà"');
    if (_all && _auto && _end == null) {
      return setState(() => _error = 'Khi cần tất cả điều kiện, hẹn giờ phải là một khung giờ: chọn giờ kết thúc');
    }
    // Chỉ giữ cảm biến còn tồn tại (cảm biến đã xoá sẽ bị máy chủ từ chối).
    final sensorIds = widget.model.devices.where((d) => d.isAlertSensor).map((d) => d.id).toSet();
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = widget.model;
    // Chỉ giữ cảm biến còn tồn tại trong căn hộ (cảm biến đã xoá sẽ bị máy chủ từ chối).
    final known = m.devices.where((d) => d.isAlertSensor).map((d) => d.id).toSet();
    final alerts = _alerts.where(known.contains).toList();
    final body = {
      'name': name,
      'icon': _kind.id,
      'actions': actions,
      'auto_enabled': _auto,
      'auto_time': _timeText,
      'auto_days': (_days.toList()..sort()),
      'alert_devices': alerts,
      'auto_leave': _leave,
      'auto_arrive': _arrive,
      'auto_time_end': _end == null ? '' : _hm(_end!),
      'trigger_sensors': [
        for (final t in _sensorTriggers)
          if (sensorIds.contains(t.deviceId)) t.toJson(),
      ],
      'trigger_logic': _logic,
      // Chỉ giữ loa còn tồn tại (loa đã xoá sẽ bị máy chủ từ chối); câu rỗng = xoá câu tuỳ chỉnh.
      'speaker_ids': _speakers.where(m.speakers.map((x) => x.id).toSet().contains).toList(),
      'speak_text': _speakText.text.trim(),
      'step_delay_ms': _stepDelay,
    };
    try {
      // Bật cảnh báo thì xin quyền hiển thị thông báo đúng lúc này (không hỏi khi mở app).
      if (alerts.isNotEmpty && await Notifier.requestPermission()) unawaited(PushService.sync(m.api));
      if (_editing) {
        await m.api.updateScene(widget.scene!.id, body);
      } else {
        await m.api.createScene(m.home!.id, body);
      }
      await m.reloadScenes();
      // Ngữ cảnh "rời nhà": xin quyền vị trí "Luôn luôn" đúng lúc này để geofence chạy được khi app đóng.
      if (_leave || _arrive) await m.enableLocationTracking();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Chọn cảm biến hiện diện / cửa sẽ báo khi ngữ cảnh này đang bật.
  List<Widget> _alertSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sensors = widget.model.devices.where((d) => d.isAlertSensor).toList();
    return [
      const SectionHeader(
        icon: Icons.notifications_active_rounded,
        colors: Vivid.alert,
        title: 'Cảnh báo cảm biến',
        info:
            'Khi ngữ cảnh này đang bật (chạy bằng tay, theo giờ hoặc khi rời nhà), mỗi lần cảm biến được chọn phát hiện có người hoặc cửa mở, thành viên nhận thông báo đẩy.',
      ),
      if (sensors.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Căn hộ chưa có cảm biến hiện diện hoặc cửa.', style: TextStyle(color: cs.onSurfaceVariant)),
        ),
      for (final d in sensors)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          secondary: IconBadge(
            d.hasDoor ? Icons.door_front_door_rounded : Icons.directions_walk_rounded,
            colors: d.hasDoor ? Vivid.leave : Vivid.alert,
            size: 34,
          ),
          title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          value: _alerts.contains(d.id),
          onChanged: (v) => setState(() => v ? _alerts.add(d.id) : _alerts.remove(d.id)),
        ),
    ];
  }

  /// Bật/tắt lần lượt: giãn cách giữa từng gang khi ngữ cảnh chạy, để đèn không bật/tắt đồng loạt.
  List<Widget> _staggerSection(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final steps = _plan.values.fold<int>(0, (n, p) => n + p.length);
    return [
      const SectionHeader(
        icon: Icons.timelapse_rounded,
        colors: Vivid.scene,
        title: 'Bật/tắt lần lượt',
        info:
            'Khi ngữ cảnh chạy, từng đèn (từng gang công tắc) được bật/tắt lần lượt theo thứ tự trong danh sách, cách nhau khoảng đã chọn, thay vì tất cả cùng lúc. '
            'Gang đã ở đúng trạng thái thì bỏ qua, không phải chờ. Chạy một ngữ cảnh khác trong lúc đang chạy lần lượt sẽ dừng ngữ cảnh này lại.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final ms in const [0, 500, 1000, 2000, 3000, 5000])
            ChoiceChip(
              label: Text(ms == 0 ? 'Cùng lúc' : Scene.delayLabel(ms)),
              selected: _stepDelay == ms,
              onSelected: (_) => setState(() => _stepDelay = ms),
            ),
        ],
      ),
      if (_stepDelay > 0 && steps > 1)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '$steps gang · chạy xong trong khoảng ${Scene.delayLabel(_stepDelay * (steps - 1))}',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 16),
    ];
  }

  /// Đặt vị trí căn hộ = vị trí hiện tại của quản trị (nên bấm khi đang ở nhà).
  Future<void> _setLocation() async {
    final m = widget.model;
    setState(() {
      _locBusy = true;
      _error = null;
    });
    try {
      final pos = await GeofenceService.currentPosition();
      if (pos == null) {
        if (mounted) setState(() => _error = 'Không lấy được vị trí. Hãy bật dịch vụ vị trí và cho phép app truy cập vị trí.');
      } else {
        await m.setHomeLocation(pos.latitude, pos.longitude, _radius);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _locBusy = false);
  }

  Future<void> _setRadius(int r) async {
    setState(() => _radius = r);
    final h = widget.model.home;
    if (h != null && h.hasLocation) {
      try {
        await widget.model.setHomeLocation(h.geoLat!, h.geoLng!, r);
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
      }
      if (mounted) setState(() {});
    }
  }

  /// Thông báo giọng nói qua loa Cast khi ngữ cảnh tự chạy (theo giờ hoặc khi rời nhà).
  List<Widget> _speakSection(BuildContext context) {
    final name = _name.text.trim().isEmpty ? 'Đi vắng' : _name.text.trim();
    return [
      const SectionHeader(
        icon: Icons.record_voice_over_rounded,
        colors: Vivid.speak,
        title: 'Thông báo qua loa',
        info:
            'Loa Google Home / Nest Mini đọc thông báo bằng tiếng Việt khi ngữ cảnh TỰ chạy (theo giờ, rời/về nhà hoặc cảm biến). Bấm chạy tay thì loa không đọc. Để trống câu đọc để dùng câu tự sinh.',
      ),
      SpeakPicker(model: widget.model, selected: _speakers, text: _speakText, hint: 'Đã chuyển sang chế độ $name', onChanged: () => setState(() {})),
      const SizedBox(height: 4),
    ];
  }

  /// Một dòng điều kiện: biểu tượng, tên, mô tả ngắn, công tắc bật/tắt; nội dung chi tiết hiện bên dưới khi bật.
  Widget _condCard(
    BuildContext context, {
    required IconData icon,
    required List<Color> colors,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    List<Widget> children = const [],
  }) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .4), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconBadge(icon, colors: colors, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(subtitle, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
          if (value && children.isNotEmpty) ...[const SizedBox(height: 8), ...children],
        ],
      ),
    );
  }

  /// Vị trí căn hộ (dùng chung cho rời nhà / về nhà).
  List<Widget> _locationRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final h = widget.model.home;
    final has = h?.hasLocation == true;
    return [
      Row(
        children: [
          Icon(has ? Icons.location_on_rounded : Icons.location_off_rounded, color: has ? cs.primary : cs.error),
          const SizedBox(width: 8),
          Expanded(child: Text(has ? 'Vị trí căn hộ · ${h!.geoRadius} m' : 'Chưa đặt vị trí căn hộ')),
          FilledButton.tonal(
            onPressed: _locBusy || _busy ? null : _setLocation,
            child: _locBusy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(has ? 'Cập nhật' : 'Vị trí hiện tại'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        children: [
          for (final r in const [100, 150, 300, 500]) ChoiceChip(label: Text('$r m'), selected: _radius == r, onSelected: (_) => _setRadius(r)),
        ],
      ),
      const SizedBox(height: 4),
    ];
  }

  /// Điều kiện tự kích hoạt: hẹn giờ, rời nhà, về nhà, cảm biến; kết hợp HOẶC / VÀ.
  List<Widget> _triggerSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    const dayNames = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];
    final sensors = widget.model.devices.where((d) => d.isAlertSensor).toList();
    final byId = {for (final d in sensors) d.id: d};
    final days = Scene.daysLabel(_days.toList()..sort());
    return [
      const SectionHeader(
        icon: Icons.bolt_rounded,
        colors: Vivid.schedule,
        title: 'Tự động kích hoạt',
        info:
            'Ngữ cảnh tự chạy khi điều kiện xảy ra, không cần mở app.\n\n'
            '• Một điều kiện bất kỳ (HOẶC): chạy khi bất kỳ điều kiện nào xảy ra.\n'
            '• Tất cả điều kiện (VÀ): chạy khi một điều kiện xảy ra và mọi điều kiện còn lại đang đúng, ví dụ "cửa mở VÀ trong khung 18:00–23:00 VÀ có người ở nhà". '
            'Khi đó hẹn giờ là một khung giờ (cần giờ kết thúc); rời nhà = không còn ai ở nhà; về nhà = có người ở nhà; cảm biến = đang ở trạng thái đã chọn.\n\n'
            'Mỗi ngữ cảnh tự chạy tối đa một lần mỗi phút. Rời/về nhà theo vị trí điện thoại của thành viên (cần cho phép vị trí "Luôn luôn"). '
            'Bộ điều khiển trung tâm offline lúc điều kiện xảy ra thì ngữ cảnh không chạy bù.',
      ),
      if (_triggerCount > 1) ...[
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'any', label: Text('Bất kỳ'), icon: Icon(Icons.join_full_rounded)),
            ButtonSegment(value: 'all', label: Text('Tất cả'), icon: Icon(Icons.join_inner_rounded)),
          ],
          selected: {_logic},
          onSelectionChanged: (s) => setState(() => _logic = s.first),
        ),
        const SizedBox(height: 6),
        Text(
          _logic == 'all'
              ? 'Chạy khi một điều kiện xảy ra và các điều kiện còn lại đang đúng (VÀ).'
              : 'Chạy mỗi khi một trong các điều kiện dưới đây xảy ra (HOẶC).',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
      ],
      _condCard(
        context,
        icon: Icons.schedule_rounded,
        colors: Vivid.schedule,
        title: 'Hẹn giờ',
        subtitle: !_auto
            ? 'Theo giờ của căn hộ'
            : _end == null
            ? 'Lúc $_timeText · $days'
            : '$_timeText–${_hm(_end!)} · $days',
        value: _auto,
        onChanged: (v) => setState(() => _auto = v),
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickTime(end: false),
                  icon: const Icon(Icons.schedule_rounded),
                  label: Text(_end == null ? 'Lúc $_timeText' : 'Từ $_timeText', style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _end == null
                    ? TextButton.icon(onPressed: () => _pickTime(end: true), icon: const Icon(Icons.add_rounded), label: const Text('Giờ kết thúc'))
                    : InputChip(
                        label: Text('Đến ${_hm(_end!)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        onPressed: () => _pickTime(end: true),
                        onDeleted: () => setState(() => _end = null),
                      ),
              ),
            ],
          ),
          if (_all && _end == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Cần giờ kết thúc khi yêu cầu tất cả điều kiện', style: tt.bodySmall?.copyWith(color: cs.error)),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < 7; i++)
                FilterChip(
                  showCheckmark: false,
                  label: Text(dayNames[i]),
                  selected: _days.contains(i + 1),
                  onSelected: (v) => setState(() => v ? _days.add(i + 1) : _days.remove(i + 1)),
                ),
            ],
          ),
        ],
      ),
      _condCard(
        context,
        icon: Icons.directions_walk_rounded,
        colors: Vivid.leave,
        title: 'Rời nhà',
        subtitle: 'Người cuối cùng rời khỏi căn hộ',
        value: _leave,
        onChanged: (v) => setState(() => _leave = v),
      ),
      _condCard(
        context,
        icon: Icons.home_rounded,
        colors: Vivid.location,
        title: 'Về nhà',
        subtitle: 'Người đầu tiên về tới căn hộ',
        value: _arrive,
        onChanged: (v) => setState(() => _arrive = v),
      ),
      if (_leave || _arrive) ...[
        if (_all && _leave && _arrive)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('Không thể yêu cầu cùng lúc "rời nhà" và "về nhà"', style: tt.bodySmall?.copyWith(color: cs.error)),
          ),
        ..._locationRow(context),
      ],
      _condCard(
        context,
        icon: Icons.sensors_rounded,
        colors: Vivid.link,
        title: 'Cảm biến',
        subtitle: sensors.isEmpty
            ? 'Căn hộ chưa có cảm biến hiện diện hoặc cửa'
            : _sensorTriggers.isEmpty
            ? 'Cảm biến hiện diện / cửa thay đổi trạng thái'
            : '${_sensorTriggers.length} cảm biến',
        value: _sensorTriggers.isNotEmpty,
        onChanged: (v) => setState(() {
          if (!v) {
            _sensorTriggers.clear();
          } else if (sensors.isNotEmpty) {
            final d = sensors.first;
            _sensorTriggers.add(SceneSensorTrigger(d.id, d.hasDoor ? 'open' : 'occupied'));
          }
        }),
        children: [
          for (var i = 0; i < _sensorTriggers.length; i++) _sensorTriggerRow(context, i, byId),
          if (_sensorTriggers.length < 10)
            Align(
              alignment: Alignment.centerLeft,
              child: PopupMenuButton<String>(
                tooltip: 'Thêm cảm biến',
                onSelected: (id) => setState(() {
                  final d = byId[id]!;
                  _sensorTriggers.add(SceneSensorTrigger(id, d.hasDoor ? 'open' : 'occupied'));
                }),
                itemBuilder: (_) => [for (final d in sensors) PopupMenuItem(value: d.id, child: Text(d.name))],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, color: cs.primary),
                      const SizedBox(width: 6),
                      Text('Thêm cảm biến', style: TextStyle(color: cs.primary)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
    ];
  }

  /// Một điều kiện cảm biến: tên + chọn trạng thái (có người / hết người, cửa mở / đóng) + bỏ.
  Widget _sensorTriggerRow(BuildContext context, int i, Map<String, Device> byId) {
    final cs = Theme.of(context).colorScheme;
    final t = _sensorTriggers[i];
    final d = byId[t.deviceId];
    final events = d == null ? [t.event] : (d.hasDoor ? SceneSensorTrigger.doorEvents : SceneSensorTrigger.presenceEvents);
    // Tên trên một dòng, chọn trạng thái ở dòng dưới: tên cảm biến thường dài, không bị cắt.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(d?.hasDoor == true ? Icons.door_front_door_rounded : Icons.directions_walk_rounded, size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  d?.name ?? 'Cảm biến đã xoá',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w600, color: d == null ? cs.error : null),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Bỏ',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() => _sensorTriggers.removeAt(i)),
              ),
            ],
          ),
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [for (final e in events) ButtonSegment(value: e, label: Text(SceneSensorTrigger.label(e)))],
            selected: {t.event},
            onSelectionChanged: (s) => setState(() => _sensorTriggers[i] = SceneSensorTrigger(t.deviceId, s.first)),
          ),
        ],
      ),
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Xoá ngữ cảnh?'),
        content: Text('Xoá "${widget.scene!.name}". Thiết bị không bị ảnh hưởng.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.model.api.deleteScene(widget.scene!.id);
      await widget.model.reloadScenes();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Chọn giờ bắt đầu (`end = false`) hoặc giờ kết thúc khung giờ.
  Future<void> _pickTime({bool end = false}) async {
    final t = await showTimePicker(
      context: context,
      helpText: end ? 'Giờ kết thúc' : 'Giờ bắt đầu',
      initialTime: end ? (_end ?? TimeOfDay(hour: (_time.hour + 4) % 24, minute: _time.minute)) : _time,
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: w!),
    );
    if (t == null) return;
    setState(() => end ? _end = t : _time = t);
  }

  void _set(String deviceId, String key, String? v) => setState(() {
    final p = _plan.putIfAbsent(deviceId, () => {});
    if (v == null) {
      p.remove(key);
    } else {
      p[key] = v;
    }
    if (p.isEmpty) _plan.remove(deviceId);
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final devices = widget.model.devices.where((d) => d.switchKeys.isNotEmpty || d.isCover).toList();
    final rooms = {for (final r in widget.model.rooms) r.id: r.name};
    final others = widget.model.devices.where((d) => d.switchKeys.isEmpty && !d.isCover).toList(); // cảm biến… không có bật/tắt
    final known = devices.map((d) => d.id).toSet();
    final missing = _plan.keys.where((id) => !known.contains(id)).length; // thiết bị đã bị xoá khỏi căn hộ
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .92),
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_editing ? 'Sửa ngữ cảnh' : 'Ngữ cảnh mới', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                autofocus: !_editing,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Tên ngữ cảnh', hintText: 'vd: Đi ngủ', counterText: ''),
              ),
              const SizedBox(height: 16),
              const SectionHeader(icon: Icons.palette_rounded, colors: Vivid.scene, title: 'Biểu tượng'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final k in SceneKind.values)
                    ChoiceChip(
                      showCheckmark: false,
                      avatar: Icon(k.icon, size: 18, color: k == _kind ? cs.onPrimaryContainer : sceneColors(k.id).first),
                      label: Text(k.label),
                      selected: k == _kind,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              SectionHeader(
                icon: Icons.toggle_on_rounded,
                colors: Vivid.device,
                title: 'Thiết bị',
                info:
                    'Với mỗi gang công tắc chọn Bật hoặc Tắt; với rèm chọn Mở hoặc Đóng; bỏ trống để giữ nguyên.${others.isEmpty ? '' : '\n\n${others.length} thiết bị không có công tắc bật/tắt nên không đưa vào ngữ cảnh: ${others.map((d) => d.name).join(', ')}.'}',
              ),
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('Căn hộ chưa có công tắc nào.', style: TextStyle(color: cs.onSurfaceVariant)),
                ),
              for (final d in devices)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .4), borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(rooms[d.roomId] ?? 'Chưa phân phòng', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      if (d.isCover)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              const Expanded(child: Text('Rèm / cửa cuốn')),
                              SegmentedButton<String>(
                                showSelectedIcon: false,
                                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                                emptySelectionAllowed: true,
                                segments: const [
                                  ButtonSegment(value: 'OPEN', label: Text('Mở')),
                                  ButtonSegment(value: 'CLOSE', label: Text('Đóng')),
                                ],
                                selected: {if (_plan[d.id]?['state'] != null) _plan[d.id]!['state']!},
                                onSelectionChanged: (s) => _set(d.id, 'state', s.isEmpty ? null : s.first),
                              ),
                            ],
                          ),
                        ),
                      for (final key in d.switchKeys)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Expanded(child: Text(d.labelFor(key), overflow: TextOverflow.ellipsis)),
                              SegmentedButton<String>(
                                showSelectedIcon: false,
                                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                                emptySelectionAllowed: true,
                                segments: const [
                                  ButtonSegment(value: 'ON', label: Text('Bật')),
                                  ButtonSegment(value: 'OFF', label: Text('Tắt')),
                                ],
                                selected: {if (_plan[d.id]?[key] != null) _plan[d.id]![key]!},
                                onSelectionChanged: (s) => _set(d.id, key, s.isEmpty ? null : s.first),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              if (missing > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '$missing thiết bị trong ngữ cảnh đã bị xoá khỏi căn hộ; chúng sẽ bị bỏ khi bạn lưu.',
                    style: tt.bodySmall?.copyWith(color: cs.error),
                  ),
                ),
              const SizedBox(height: 12),
              ..._staggerSection(context),
              ..._alertSection(context),
              const SizedBox(height: 4),
              ..._triggerSection(context),
              const Divider(height: 24),
              ..._speakSection(context),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: cs.error)),
                ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (_editing)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: cs.error),
                      onPressed: _busy ? null : _delete,
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Xoá'),
                    ),
                  const Spacer(),
                  TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Huỷ')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _busy ? null : _save, child: Text(_editing ? 'Lưu' : 'Tạo')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
