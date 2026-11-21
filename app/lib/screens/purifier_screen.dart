import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';
import '../widgets/ui.dart';
import 'device_edit_dialog.dart';

/// Máy lọc nước Bluetooth (Karofi) đọc qua addon trong nhà: chất lượng nước (TDS), tuổi thọ từng lõi lọc, lỗi của máy.
String purifierError(Object e) {
  final t = e.toString();
  if (t.contains('bluetooth_off')) return 'Bluetooth của máy chạy addon đang tắt. Trên máy đó chạy: sudo rfkill unblock bluetooth';
  if (t.contains('bluetooth_unavailable')) return 'Addon không dùng được Bluetooth (cần BlueZ và mount /run/dbus vào container)';
  if (t.contains('not found nearby')) return 'Không thấy máy lọc: để máy chạy addon gần máy lọc hơn rồi thử lại';
  if (t.contains('already added')) return 'Máy lọc này đã được thêm qua addon khác';
  if (t.contains('too many')) return 'Căn hộ đã có tối đa 8 máy lọc';
  if (t.contains('addon offline') || t.contains('did not respond')) return 'Addon trong nhà đang offline';
  if (t.contains('unreachable')) return 'Không đọc được số liệu từ máy lọc. Kiểm tra máy đang bật nguồn và ở gần addon';
  return t;
}

String qualityLabel(String q) => switch (q) {
  'good' => 'Tốt',
  'fair' => 'Khá',
  'poor' => 'Kém',
  _ => 'Chưa rõ',
};

Color qualityColor(String q) => switch (q) {
  'good' => const Color(0xFF16A34A),
  'fair' => const Color(0xFFF59E0B),
  'poor' => const Color(0xFFEF4444),
  _ => const Color(0xFF94A3B8),
};

Color filterColor(int? p) => p == null
    ? const Color(0xFF94A3B8)
    : p <= 10
    ? const Color(0xFFEF4444)
    : p <= 25
    ? const Color(0xFFF59E0B)
    : const Color(0xFF06B6D4);

/// Nội dung thẻ máy lọc trên màn căn hộ: TDS + lõi lọc thấp nhất + lỗi (nếu có).
class PurifierSummary extends StatelessWidget {
  final Device device;
  const PurifierSummary({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    final d = device;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final errs = d.purifierErrors;
    Widget tile(IconData icon, String label, String value, Color color) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .55), borderRadius: BorderRadius.circular(18)),
      child: Row(
        children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
    final low = d.filterMin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: tile(Icons.water_drop_rounded, 'TDS · ${qualityLabel(d.waterQuality)}', d.tds == null ? '—' : '${d.tds} ppm', qualityColor(d.waterQuality)),
            ),
            const SizedBox(width: 10),
            Expanded(child: tile(Icons.filter_alt_rounded, 'Lõi lọc thấp nhất', low == null ? '—' : '$low%', filterColor(low))),
          ],
        ),
        if (errs.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(errs.map(purifierErrorText).join(' · '), style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

void openPurifier(BuildContext context, Device d) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => PurifierScreen(deviceId: d.id)));

class PurifierScreen extends StatelessWidget {
  final String deviceId;
  const PurifierScreen({super.key, required this.deviceId});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final d = m.devices.where((x) => x.id == deviceId).firstOrNull;
    if (d == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Máy lọc đã bị gỡ')));
    }
    final role = m.home?.role;
    final admin = m.home?.isAdmin == true;
    final canReset = admin || role == 'member';
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final room = m.rooms.where((r) => r.id == d.roomId).firstOrNull;
    final q = d.waterQuality;
    final filters = d.filters;

    return Scaffold(
      appBar: AppBar(
        title: Text(d.name),
        actions: [
          if (admin)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') showDeviceEditDialog(context, m, d);
                if (v == 'remove') await _remove(context, m, d);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Đổi tên / phòng'))),
                PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.delete_outline_rounded), title: Text('Gỡ máy lọc'))),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    children: [
                      const IconBadge(Icons.water_drop_rounded, colors: Vivid.water, size: 46),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Nước sau lọc', style: tt.titleMedium),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                Pill(
                                  d.online ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                                  d.online ? 'Đang kết nối' : 'Mất kết nối',
                                  color: d.online ? const Color(0xFF16A34A) : cs.error,
                                ),
                                if (room != null) Pill(room.kind.icon, room.name),
                                if ((d.model ?? '').isNotEmpty) Pill(Icons.memory_rounded, d.model!),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(d.tds == null ? '—' : '${d.tds}', style: tt.displayMedium?.copyWith(fontWeight: FontWeight.w800, color: qualityColor(q))),
                  Text('ppm TDS · Chất lượng ${qualityLabel(q).toLowerCase()}', style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Text(
                    'TDS (tổng chất rắn hoà tan) đo sau màng lọc: dưới 50 ppm là tốt, 50–150 ppm là khá, trên 150 ppm nên kiểm tra máy hoặc thay lõi.',
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  if (d.state['hydrogen'] is num || d.state['water_mode'] is String) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      children: [
                        if (d.state['hydrogen'] is num) Pill(Icons.bubble_chart_rounded, 'Hydro ${d.state['hydrogen']} ppb'),
                        if (d.state['water_mode'] is String) Pill(Icons.water_rounded, _modeLabel(d.state['water_mode'] as String, d.state['alkaline_level'])),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          for (final e in d.purifierErrors)
            Card(
              color: cs.errorContainer,
              child: ListTile(
                leading: Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
                title: Text(purifierErrorText(e), style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w700)),
                subtitle: Text('Máy báo mã lỗi $e. Nếu lặp lại, liên hệ trung tâm bảo hành Karofi.', style: TextStyle(color: cs.onErrorContainer)),
              ),
            ),
          const SizedBox(height: 8),
          const SectionHeader(
            icon: Icons.filter_alt_rounded,
            colors: Vivid.water,
            title: 'Lõi lọc',
            info:
                'Máy báo thời gian còn lại của từng lõi theo lịch và theo giờ chạy bơm; % hiển thị là mức thấp hơn của hai cách tính. '
                'Sau khi thay lõi, bấm nút đặt lại để máy đếm lại từ đầu.\n\nỨng dụng nhắc khi một lõi còn 10% hoặc ít hơn.',
          ),
          if (filters.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Chưa nhận được số liệu lõi lọc. Máy sẽ cập nhật trong vài phút.', style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            ),
          for (final f in filters) _FilterCard(device: d, filter: f, canReset: canReset && d.online),
        ],
      ),
    );
  }

  static String _modeLabel(String mode, dynamic level) {
    final l = level is num ? ' mức ${level.toInt()}' : '';
    return switch (mode) {
      'pure' => 'Nước tinh khiết',
      'alkaline' => 'Nước kiềm$l',
      'hydrogen' => 'Nước giàu hydro',
      'skin_care' => 'Nước dưỡng da',
      'hot' => 'Nước nóng',
      'cold' => 'Nước lạnh',
      'ambient' => 'Nước thường',
      'soda' => 'Nước soda',
      _ => 'Chế độ khác$l',
    };
  }

  Future<void> _remove(BuildContext context, AppModel m, Device d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Gỡ máy lọc?'),
        content: Text('"${d.name}" sẽ không còn hiện trong ứng dụng và Google Home. Máy lọc vẫn chạy bình thường.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Gỡ')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final nav = Navigator.of(context);
    final msg = ScaffoldMessenger.of(context);
    try {
      await m.api.deleteDevice(d.id);
      await m.reload();
      nav.pop();
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(purifierError(e))));
    }
  }
}

class _FilterCard extends StatelessWidget {
  final Device device;
  final PurifierFilter filter;
  final bool canReset;
  const _FilterCard({required this.device, required this.filter, required this.canReset});

  @override
  Widget build(BuildContext context) {
    final f = filter;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final color = filterColor(f.percent);
    final details = [
      if (f.daysLeft != null) 'Còn ${f.daysLeft} ngày${f.lifeDays != null ? ' / ${f.lifeDays}' : ''}',
      if (f.hoursLeft != null) '${f.hoursLeft} giờ chạy${f.hoursTotal != null ? ' / ${f.hoursTotal}' : ''}',
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(f.label, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
                Text(f.percent == null ? '—' : '${f.percent}%', style: tt.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w800)),
                if (canReset)
                  IconButton(
                    tooltip: 'Đã thay lõi',
                    icon: const Icon(Icons.restart_alt_rounded),
                    onPressed: () => _reset(context),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: (f.percent ?? 0) / 100,
                  minHeight: 8,
                  color: color,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(details, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _reset(BuildContext context) async {
    final m = context.read<AppModel>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Đã thay ${filter.label.toLowerCase()}?'),
        content: const Text('Máy lọc sẽ đếm lại tuổi thọ lõi này từ đầu. Chỉ bấm sau khi đã lắp lõi mới.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Đặt lại')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await m.send(device, {'reset_filter': filter.no});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m.error == null ? 'Đã gửi lệnh tới máy lọc. Số liệu cập nhật sau vài giây.' : purifierError(m.error!))),
      );
    }
  }
}

// ───────────────────────── thêm máy lọc ─────────────────────────

Future<void> showAddPurifierSheet(BuildContext context) => showCenterSheet<void>(context: context, builder: (_) => const _AddPurifierSheet());

class _AddPurifierSheet extends StatefulWidget {
  const _AddPurifierSheet();
  @override
  State<_AddPurifierSheet> createState() => _AddPurifierSheetState();
}

class _AddPurifierSheetState extends State<_AddPurifierSheet> {
  late final AppModel _m = context.read<AppModel>();
  final _name = TextEditingController(text: 'Máy lọc nước');
  bool _scanning = false, _saving = false;
  List<Map<String, dynamic>>? _found;
  Map<String, dynamic>? _picked;
  String? _roomId, _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      _found = await _m.api.scanPurifiers(_m.home!.id);
      final fresh = _found!.where((f) => f['added'] != true).toList();
      if (fresh.length == 1) _picked = fresh.first;
    } catch (e) {
      _error = purifierError(e);
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _save() async {
    final p = _picked;
    if (p == null) return setState(() => _error = 'Chọn máy lọc cần thêm');
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Đặt tên cho máy lọc');
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _m.api.addPurifier(_m.home!.id, {'mac': p['mac'], 'name': name, 'room_id': ?_roomId, 'gateway_id': p['gateway_id']});
      await _m.reload();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = purifierError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            children: [
              Row(
                children: [
                  const IconBadge(Icons.water_drop_rounded, colors: Vivid.water, size: 44),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Thêm máy lọc nước', style: tt.titleLarge)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Máy lọc Karofi có Bluetooth (tên dạng TCM-…). Addon trong nhà đọc máy qua Bluetooth nên cần đặt cách máy lọc khoảng 10 m trở lại.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _scanning || _saving ? null : _scan,
                icon: _scanning ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.bluetooth_searching_rounded),
                label: Text(_scanning ? 'Đang tìm máy lọc…' : 'Tìm lại'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              ),
              if (_found != null) ...[
                const SizedBox(height: 8),
                if (_found!.isEmpty)
                  Text('Không thấy máy lọc nào. Kiểm tra máy lọc đang bật nguồn và ở gần addon.', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                for (final f in _found!)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const IconBadge(Icons.water_drop_outlined, colors: Vivid.water, size: 32),
                    title: Text((f['name'] as String?)?.isNotEmpty == true ? f['name'] : 'Máy lọc Karofi'),
                    subtitle: Text('${f['mac']}${f['rssi'] != null ? ' · sóng ${f['rssi']} dBm' : ''}'),
                    trailing: f['added'] == true
                        ? const Text('Đã thêm')
                        : (_picked?['mac'] == f['mac'] ? Icon(Icons.check_circle_rounded, color: cs.primary) : null),
                    enabled: f['added'] != true && !_saving,
                    onTap: () => setState(() => _picked = f),
                  ),
              ],
              const SizedBox(height: 14),
              TextField(controller: _name, maxLength: 60, decoration: const InputDecoration(labelText: 'Tên máy lọc', counterText: '')),
              const SizedBox(height: 14),
              Text('Phòng', style: tt.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(showCheckmark: false, label: const Text('Không chọn'), selected: _roomId == null, onSelected: (_) => setState(() => _roomId = null)),
                  for (final r in _m.rooms)
                    ChoiceChip(
                      showCheckmark: false,
                      avatar: Icon(r.kind.icon, size: 18),
                      label: Text(r.name),
                      selected: _roomId == r.id,
                      onSelected: (_) => setState(() => _roomId = r.id),
                    ),
                ],
              ),
              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
                  child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
                ),
              if (_saving)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Đang kết nối máy lọc và đọc số liệu (tối đa 1 phút)…', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    child: const Text('Huỷ'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _saving || _picked == null ? null : _save,
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    child: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Thêm'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
