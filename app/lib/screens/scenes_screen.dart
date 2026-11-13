import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';

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
      msg.showSnackBar(SnackBar(content: Text(sent == total ? 'Đã chạy "${s.name}"' : 'Đã gửi $sent/$total lệnh của "${s.name}"')));
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(e.toString().contains('gateway offline') ? 'Bộ điều khiển trung tâm đang offline' : e.toString())));
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _edit(Scene? s) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
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
      appBar: AppBar(title: const Text('Ngữ cảnh')),
      floatingActionButton: home.isAdmin
          ? FloatingActionButton.extended(onPressed: () => _edit(null), icon: const Icon(Icons.add_rounded), label: const Text('Tạo ngữ cảnh'))
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 120), children: [
          if (_error != null)
            Card(
              color: cs.errorContainer,
              child: ListTile(leading: Icon(Icons.error_outline, color: cs.onErrorContainer), title: Text(_error!, style: TextStyle(color: cs.onErrorContainer)), trailing: TextButton(onPressed: _load, child: const Text('Thử lại'))),
            ),
          if (scenes == null && _error == null) const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: CircularProgressIndicator())),
          if (scenes != null && scenes.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 64, 24, 0),
              child: Column(children: [
                Icon(Icons.auto_awesome_rounded, size: 56, color: cs.primary.withValues(alpha: .6)),
                const SizedBox(height: 16),
                Text('Chưa có ngữ cảnh', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  home.isAdmin
                      ? 'Tạo ngữ cảnh như "Đi ngủ" (tắt hết đèn) hay "Về nhà" (bật đèn phòng khách), rồi đặt giờ để tự kích hoạt.'
                      : 'Quản trị căn hộ có thể tạo ngữ cảnh để bật/tắt nhiều thiết bị cùng lúc.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ]),
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
        ]),
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
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(16)),
              child: Icon(scene.kind.icon, color: cs.onPrimaryContainer),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(scene.name, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('${scene.actions.length} thiết bị', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 6),
                if (scene.autoEnabled && scene.autoTime != null)
                  Row(children: [
                    Icon(Icons.schedule_rounded, size: 16, color: cs.primary),
                    const SizedBox(width: 4),
                    Flexible(child: Text('Tự động ${scene.autoTime} · ${Scene.daysLabel(scene.autoDays)}', style: tt.bodySmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w600))),
                  ])
                else
                  Text('Chạy thủ công', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                if (status != null && scene.autoEnabled)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(status, style: tt.bodySmall?.copyWith(color: bad ? cs.error : cs.onSurfaceVariant)),
                  ),
              ]),
            ),
            if (canRun)
              running
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)))
                  : IconButton.filledTonal(onPressed: onRun, icon: const Icon(Icons.play_arrow_rounded), tooltip: 'Chạy ngay'),
          ]),
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
  late bool _auto = widget.scene?.autoEnabled ?? false;
  late TimeOfDay _time = _parse(widget.scene?.autoTime) ?? const TimeOfDay(hour: 18, minute: 0);
  late final Set<int> _days = {...(widget.scene?.autoDays ?? [1, 2, 3, 4, 5, 6, 7])};
  bool _busy = false;
  String? _error;

  bool get _editing => widget.scene != null;

  static TimeOfDay? _parse(String? s) {
    if (s == null) return null;
    final p = s.split(':');
    if (p.length != 2) return null;
    return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
  }

  String get _timeText => '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

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
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = widget.model;
    final body = {
      'name': name,
      'icon': _kind.id,
      'actions': actions,
      'auto_enabled': _auto,
      'auto_time': _timeText,
      'auto_days': (_days.toList()..sort()),
    };
    try {
      if (_editing) {
        await m.api.updateScene(widget.scene!.id, body);
      } else {
        await m.api.createScene(m.home!.id, body);
      }
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

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Xoá ngữ cảnh?'),
        content: Text('Xoá "${widget.scene!.name}". Thiết bị không bị ảnh hưởng.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error), onPressed: () => Navigator.pop(c, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.model.api.deleteScene(widget.scene!.id);
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

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time, builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: w!));
    if (t != null) setState(() => _time = t);
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
    final devices = widget.model.devices.where((d) => d.switchKeys.isNotEmpty).toList();
    final rooms = {for (final r in widget.model.rooms) r.id: r.name};
    final known = devices.map((d) => d.id).toSet();
    final missing = _plan.keys.where((id) => !known.contains(id)).length; // thiết bị đã bị xoá khỏi căn hộ
    const dayNames = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .92),
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
            Text('Biểu tượng', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final k in SceneKind.values)
                ChoiceChip(
                  showCheckmark: false,
                  avatar: Icon(k.icon, size: 18, color: k == _kind ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                  label: Text(k.label),
                  selected: k == _kind,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ]),
            const SizedBox(height: 20),
            Text('Thiết bị', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('Với mỗi công tắc chọn Bật, Tắt hoặc giữ nguyên.', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (devices.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text('Căn hộ chưa có công tắc nào.', style: TextStyle(color: cs.onSurfaceVariant))),
            for (final d in devices)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .4), borderRadius: BorderRadius.circular(16)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(rooms[d.roomId] ?? 'Chưa phân phòng', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  for (final key in d.switchKeys)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Expanded(child: Text(d.labelFor(key), overflow: TextOverflow.ellipsis)),
                        SegmentedButton<String>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(visualDensity: VisualDensity.compact),
                          emptySelectionAllowed: true,
                          segments: const [ButtonSegment(value: 'ON', label: Text('Bật')), ButtonSegment(value: 'OFF', label: Text('Tắt'))],
                          selected: {if (_plan[d.id]?[key] != null) _plan[d.id]![key]!},
                          onSelectionChanged: (s) => _set(d.id, key, s.isEmpty ? null : s.first),
                        ),
                      ]),
                    ),
                ]),
              ),
            if (missing > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('$missing thiết bị trong ngữ cảnh đã bị xoá khỏi căn hộ; chúng sẽ bị bỏ khi bạn lưu.', style: tt.bodySmall?.copyWith(color: cs.error)),
              ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tự động kích hoạt', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Chạy ngữ cảnh vào giờ đã chọn, không cần mở app'),
              value: _auto,
              onChanged: (v) => setState(() => _auto = v),
            ),
            if (_auto) ...[
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: _pickTime,
                icon: const Icon(Icons.schedule_rounded),
                label: Text('Lúc $_timeText', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (var i = 0; i < 7; i++)
                  FilterChip(
                    showCheckmark: false,
                    label: Text(dayNames[i]),
                    selected: _days.contains(i + 1),
                    onSelected: (v) => setState(() => v ? _days.add(i + 1) : _days.remove(i + 1)),
                  ),
              ]),
              const SizedBox(height: 8),
              Text(
                'Giờ theo múi giờ của căn hộ. Nếu bộ điều khiển trung tâm offline lúc đến giờ, ngữ cảnh được thử lại trong 5 phút; quá thời gian đó sẽ bị bỏ lỡ chứ không chạy bù muộn.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: cs.error))),
            const SizedBox(height: 20),
            Row(children: [
              if (_editing)
                TextButton.icon(style: TextButton.styleFrom(foregroundColor: cs.error), onPressed: _busy ? null : _delete, icon: const Icon(Icons.delete_outline_rounded), label: const Text('Xoá')),
              const Spacer(),
              TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Huỷ')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _busy ? null : _save, child: Text(_editing ? 'Lưu' : 'Tạo')),
            ]),
          ]),
        ),
      ),
    );
  }
}
