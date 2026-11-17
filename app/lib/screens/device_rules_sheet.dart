import 'package:flutter/material.dart';

import '../app_model.dart';
import '../models.dart';
import '../widgets/ui.dart';
import 'speak_picker.dart';

/// Màn cài đặt luật tự động (biểu tượng tia sét) cho một thiết bị: chọn gang, rồi đặt
/// tự tắt sau khi bật, tự bật lại sau khi tắt, và đồng kích hoạt theo gang của thiết bị khác.
Future<void> showDeviceRulesSheet(BuildContext context, AppModel m, Device d) {
  return showCenterSheet<void>(
    context: context,
    builder: (_) => _RulesSheet(model: m, device: d),
  );
}

class _RulesSheet extends StatefulWidget {
  final AppModel model;
  final Device device;
  const _RulesSheet({required this.model, required this.device});
  @override
  State<_RulesSheet> createState() => _RulesSheetState();
}

class _RulesSheetState extends State<_RulesSheet> {
  late String _key = widget.device.switchKeys.first;
  bool _busy = false;
  String? _error;

  AppModel get m => widget.model;
  Device get d => widget.device;

  DeviceRule? _timer(String kind) {
    for (final r in m.rules) {
      if (r.deviceId == d.id && r.key == _key && r.kind == kind) return r;
    }
    return null;
  }

  List<DeviceRule> get _links => [
    for (final r in m.rules)
      if (r.deviceId == d.id && r.key == _key && r.kind == 'link') r,
  ];

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
      await m.reloadRules();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleTimer(String kind, bool on) => _run(() async {
    final r = _timer(kind);
    if (on && r == null) {
      await m.api.createRule(m.home!.id, {'device_id': d.id, 'key': _key, 'kind': kind, 'delay_s': 300});
    } else if (!on && r != null) {
      await m.api.deleteRule(r.id);
    }
  });

  Future<void> _editDelay(DeviceRule r) async {
    final s = await _pickDelay(context, r.delaySeconds ?? 300);
    if (s != null) await _run(() => m.api.updateRule(r.id, {'delay_s': s}));
  }

  Future<void> _speak(DeviceRule r, String hint) async {
    final res = await showSpeakDialog(context, m, ids: r.speakerIds, text: r.speakText, hint: hint);
    if (res != null) await _run(() => m.api.updateRule(r.id, {'speaker_ids': res.ids, 'speak_text': res.text}));
  }

  String _speakLabel(DeviceRule r) => r.speakerIds.isEmpty ? 'Đọc qua loa: tắt' : 'Đọc qua loa: ${r.speakerIds.length} loa';

  Future<void> _addLink() async {
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LinkDialog(model: m, target: d, targetKey: _key),
    );
    if (body != null) await _run(() => m.api.createRule(m.home!.id, body));
  }

  String _deviceName(String id) => m.devices.where((x) => x.id == id).map((x) => x.name).firstOrNull ?? 'Thiết bị đã xoá';
  String _gangName(String id, String key) {
    final x = m.devices.where((x) => x.id == id).firstOrNull;
    return x == null ? key : x.labelFor(key);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IconBadge(Icons.bolt_rounded, colors: Vivid.timer, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(d.name, style: tt.titleLarge, overflow: TextOverflow.ellipsis),
                  ),
                  const InfoTip(
                    'Tự động hoá',
                    'Luật chạy trên máy chủ nên cần bộ điều khiển trung tâm online. Áp dụng cho mọi cách bật/tắt: app, ngữ cảnh, Google Home, công tắc vật lý (nếu công tắc báo trạng thái). Hẹn giờ bị huỷ nếu gang đổi trạng thái trước hạn.',
                  ),
                ],
              ),
              if (d.switchKeys.length > 1) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final k in d.switchKeys) ChoiceChip(label: Text(d.labelFor(k)), selected: _key == k, onSelected: (_) => setState(() => _key = k)),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              _timerTile('auto_off', 'Tự tắt', Icons.timer_off_rounded, Vivid.timer, 'Gang đang bật được bao lâu thì tự tắt.'),
              _timerTile('auto_on', 'Tự bật lại', Icons.restart_alt_rounded, Vivid.power, 'Gang đang tắt được bao lâu thì tự bật lại.'),
              const Divider(height: 28),
              SectionHeader(
                icon: Icons.link_rounded,
                colors: Vivid.link,
                title: 'Đồng kích hoạt',
                info:
                    'Khi một gang khác bật hoặc tắt thì gang "${d.labelFor(_key)}" cũng bật hoặc tắt theo. Chỉ một bước: gang bị luật điều khiển không kích hoạt tiếp luật khác (tránh vòng lặp).',
                trailing: IconButton.filledTonal(onPressed: _busy ? null : _addLink, icon: const Icon(Icons.add_rounded), tooltip: 'Thêm'),
              ),
              for (final r in _links)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: IconBadge(
                    r.sourceState == 'ON' ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
                    colors: Vivid.link,
                    size: 36,
                    muted: !r.enabled,
                  ),
                  title: Text(
                    '${_deviceName(r.sourceDeviceId ?? '')} · ${_gangName(r.sourceDeviceId ?? '', r.sourceKey ?? '')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Row(
                    children: [
                      Pill(Icons.power_settings_new_rounded, r.sourceState == 'ON' ? 'bật' : 'tắt'),
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.arrow_forward_rounded, size: 16)),
                      Pill(Icons.power_settings_new_rounded, r.targetState == 'ON' ? 'bật' : 'tắt', color: Vivid.link.first),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    tooltip: 'Xoá',
                    onPressed: _busy ? null : () => _run(() => m.api.deleteRule(r.id)),
                  ),
                ),
              if (_links.isEmpty) const Pill(Icons.inbox_rounded, 'Chưa có'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, style: TextStyle(color: cs.error)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timerTile(String kind, String title, IconData icon, List<Color> colors, String info) {
    final r = _timer(kind);
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: icon,
            colors: colors,
            title: title,
            info: info,
            trailing: Switch(value: r != null, onChanged: _busy ? null : (v) => _toggleTimer(kind, v)),
          ),
          if (r != null)
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.timer_rounded, size: 18),
                    label: Text(DeviceRule.delayLabel(r.delaySeconds ?? 0)),
                    onPressed: _busy ? null : () => _editDelay(r),
                  ),
                  ActionChip(
                    avatar: Icon(Icons.record_voice_over_rounded, size: 18, color: r.speakerIds.isEmpty ? null : Vivid.speak.first),
                    label: Text(r.speakerIds.isEmpty ? 'Loa' : '${r.speakerIds.length} loa'),
                    tooltip: _speakLabel(r),
                    side: r.speakerIds.isEmpty ? null : BorderSide(color: cs.primary.withValues(alpha: .4)),
                    onPressed: _busy ? null : () => _speak(r, kind == 'auto_on' ? 'Đã tự động bật lại ${d.name}' : 'Đã tự động tắt ${d.name}'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Chọn khoảng thời gian: số + đơn vị (giây / phút / giờ), 1 giây đến 24 giờ. Trả về số giây.
Future<int?> _pickDelay(BuildContext context, int initial) {
  var unit = initial % 3600 == 0 ? 3600 : (initial % 60 == 0 ? 60 : 1);
  final ctrl = TextEditingController(text: '${initial ~/ unit}');
  String? err;
  return showDialog<int>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Sau bao lâu?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(errorText: err),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('giây')),
                ButtonSegment(value: 60, label: Text('phút')),
                ButtonSegment(value: 3600, label: Text('giờ')),
              ],
              selected: {unit},
              onSelectionChanged: (s) => set(() => unit = s.first),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Huỷ')),
          FilledButton(
            onPressed: () {
              final v = (int.tryParse(ctrl.text.trim()) ?? 0) * unit;
              if (v < 1 || v > 86400) return set(() => err = 'Từ 1 giây đến 24 giờ');
              Navigator.pop(c, v);
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    ),
  );
}

class _LinkDialog extends StatefulWidget {
  final AppModel model;
  final Device target;
  final String targetKey;
  const _LinkDialog({required this.model, required this.target, required this.targetKey});
  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final List<(Device, String)> _sources = [
    for (final x in widget.model.devices)
      for (final k in x.switchKeys)
        if (!(x.id == widget.target.id && k == widget.targetKey)) (x, k),
  ];
  int _src = 0;
  String _when = 'ON';
  String _then = 'ON';

  @override
  Widget build(BuildContext context) {
    if (_sources.isEmpty) {
      return AlertDialog(
        title: const Text('Đồng kích hoạt'),
        content: const Text('Căn hộ chưa có gang nào khác để liên kết.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng'))],
      );
    }
    final seg = const [ButtonSegment(value: 'ON', label: Text('bật')), ButtonSegment(value: 'OFF', label: Text('tắt'))];
    return AlertDialog(
      title: const Text('Đồng kích hoạt'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Khi gang này'),
            const SizedBox(height: 6),
            DropdownButton<int>(
              isExpanded: true,
              value: _src,
              items: [
                for (var i = 0; i < _sources.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text('${_sources[i].$1.name} · ${_sources[i].$1.labelFor(_sources[i].$2)}', overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _src = v ?? 0),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(segments: seg, selected: {_when}, onSelectionChanged: (s) => setState(() => _when = s.first)),
            const SizedBox(height: 14),
            Text('thì "${widget.target.labelFor(widget.targetKey)}"'),
            const SizedBox(height: 6),
            SegmentedButton<String>(segments: seg, selected: {_then}, onSelectionChanged: (s) => setState(() => _then = s.first)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'device_id': widget.target.id,
            'key': widget.targetKey,
            'kind': 'link',
            'source_device_id': _sources[_src].$1.id,
            'source_key': _sources[_src].$2,
            'source_state': _when,
            'target_state': _then,
          }),
          child: const Text('Thêm'),
        ),
      ],
    );
  }
}
