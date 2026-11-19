import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';
import '../widgets/ui.dart';
import 'device_edit_dialog.dart';

/// Thời gian mở ghép nối mỗi lần (tối đa Zigbee2MQTT cho phép).
const _permitSeconds = 254;

/// Thêm thiết bị Zigbee ngay trong app: mở cho phép ghép nối trên bộ điều khiển trung tâm, hiện thiết bị vừa vào mạng
/// theo thời gian thực. Đóng popup là đóng ghép nối, để thiết bị lạ không vào được mạng.
Future<void> showPairDeviceSheet(BuildContext context) {
  return showCenterSheet<void>(context: context, barrierDismissible: false, builder: (_) => const _PairSheet());
}

class _PairSheet extends StatefulWidget {
  const _PairSheet();
  @override
  State<_PairSheet> createState() => _PairSheetState();
}

class _PairSheetState extends State<_PairSheet> {
  late final AppModel _m = context.read<AppModel>();
  Timer? _tick;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    // Đóng ghép nối khi rời popup (lỗi mạng thì Z2M tự đóng khi hết giờ).
    if (_m.permitOpen) _m.setPermitJoin(0).catchError((_) {});
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await _m.setPermitJoin(_permitSeconds);
    } catch (e) {
      _error = e.toString().contains('gateway offline') ? 'Bộ điều khiển trung tâm đang offline' : e.toString();
    }
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final open = m.permitOpen;
    final left = open ? m.permitUntil!.difference(DateTime.now()).inSeconds.clamp(0, _permitSeconds) : 0;
    final found = m.pairing.entries.toList();

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
                  const IconBadge(Icons.add_link_rounded, colors: Vivid.device, size: 44),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Thêm thiết bị Zigbee', style: tt.titleLarge)),
                ],
              ),
              const SizedBox(height: 20),
              Center(
                child: _Countdown(left: left, open: open, busy: _starting),
              ),
              const SizedBox(height: 14),
              Text(
                _error ?? (_starting ? 'Đang mở ghép nối…' : (open ? 'Đang tìm thiết bị mới' : 'Đã dừng tìm thiết bị')),
                textAlign: TextAlign.center,
                style: tt.titleMedium?.copyWith(color: _error != null ? cs.error : null),
              ),
              if (open) ...[
                const SizedBox(height: 14),
                const _Step(n: 1, text: 'Cấp điện cho thiết bị, để gần bộ điều khiển trung tâm.'),
                const _Step(n: 2, text: 'Đưa thiết bị về chế độ ghép nối theo hướng dẫn của hãng (thường giữ nút 5–10 giây đến khi đèn nháy).'),
                const _Step(n: 3, text: 'Chờ thiết bị hiện bên dưới, rồi đặt tên và chọn phòng.'),
              ],
              if (found.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Thiết bị tìm thấy', style: tt.titleSmall),
                const SizedBox(height: 6),
                for (final e in found) _FoundTile(ieee: e.key, status: e.value),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(
              children: [
                if (!open && !_starting) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _start,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Tìm lại'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton(onPressed: () => Navigator.pop(context), child: Text(open ? 'Dừng & đóng' : 'Xong')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Vòng đếm ngược thời gian còn cho phép ghép nối.
class _Countdown extends StatelessWidget {
  final int left;
  final bool open;
  final bool busy;
  const _Countdown({required this.left, required this.open, required this.busy});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mm = (left ~/ 60).toString();
    final ss = (left % 60).toString().padLeft(2, '0');
    return SizedBox(
      width: 132,
      height: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: busy ? null : (open ? left / _permitSeconds : 0),
              strokeWidth: 8,
              strokeCap: StrokeCap.round,
              backgroundColor: cs.primaryContainer,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(open ? Icons.wifi_tethering_rounded : Icons.wifi_tethering_off_rounded, color: open ? cs.primary : cs.outline, size: 30),
              if (open) Text('$mm:$ss', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String text;
  const _Step({required this.n, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: cs.primaryContainer,
            child: Text(
              '$n',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: cs.onPrimaryContainer),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Một thiết bị vừa vào mạng: trạng thái interview, và nút đặt tên khi đã vào danh sách.
class _FoundTile extends StatelessWidget {
  final String ieee;
  final PairStatus status;
  const _FoundTile({required this.ieee, required this.status});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final cs = Theme.of(context).colorScheme;
    Device? device;
    for (final d in m.devices) {
      if (d.ieee == ieee) device = d;
    }
    final title = device == null ? 'Thiết bị mới' : (device.name != ieee ? device.name : (device.description ?? device.name));
    final sub = switch (status) {
      PairStatus.joined => 'Đang nhận diện…',
      PairStatus.added => device == null ? 'Đang thêm vào danh sách…' : [device.vendor, device.model].whereType<String>().join(' · '),
      PairStatus.failed => 'Không nhận diện được — thử ghép lại',
      PairStatus.left => 'Thiết bị đã rời mạng',
    };
    final Widget trailing = switch (status) {
      PairStatus.joined => const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
      PairStatus.added when device != null => FilledButton.tonal(onPressed: () => showDeviceEditDialog(context, m, device!), child: const Text('Đặt tên')),
      PairStatus.added => Icon(Icons.check_circle_rounded, color: cs.primary),
      PairStatus.failed || PairStatus.left => Icon(Icons.error_outline_rounded, color: cs.error),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: IconBadge(
          device?.isSensor == true ? Icons.sensors_rounded : Icons.memory_rounded,
          colors: Vivid.device,
          size: 34,
          muted: status != PairStatus.added,
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
        contentPadding: const EdgeInsets.only(left: 12, right: 10),
        horizontalTitleGap: 10,
        trailing: trailing,
      ),
    );
  }
}
