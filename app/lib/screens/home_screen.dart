import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';
import 'device_edit_dialog.dart';
import 'gateways_screen.dart';
import 'matter_screen.dart';
import 'scenes_screen.dart';
import 'members_screen.dart';
import 'room_sheet.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _open(BuildContext context, Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final home = m.home!;
    final cs = Theme.of(context).colorScheme;

    // Nhóm thiết bị theo phòng; thiết bị chưa gán phòng vào "Chưa phân phòng".
    final groups = <String?, List<Device>>{};
    for (final d in m.devices) {
      groups.putIfAbsent(d.roomId, () => []).add(d);
    }
    final sections = <(Room?, List<Device>)>[
      for (final r in m.rooms) (r, groups[r.id] ?? const []),
      if ((groups[null] ?? const []).isNotEmpty) (null, groups[null]!),
    ];

    final switchesOn = m.devices.fold<int>(0, (n, d) => n + d.switchKeys.where(d.isOn).length);
    final onlineCount = m.devices.where((d) => d.online).length;
    final alerts = m.devices.fold<int>(0, (n, d) => n + d.readings.where((r) => r.alert && r.label != 'Hiện diện').length);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: m.reload,
        child: CustomScrollView(slivers: [
          SliverAppBar.large(
            leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: m.leaveHome),
            title: Text(home.name),
            actions: [
              IconButton(icon: const Icon(Icons.auto_awesome_rounded), tooltip: 'Ngữ cảnh', onPressed: () => _open(context, const ScenesScreen())),
              if (home.isAdmin)
                IconButton(icon: const Icon(Icons.qr_code_2_rounded), tooltip: 'Google Home / Apple Home', onPressed: () => _open(context, const MatterScreen())),
              if (home.isAdmin)
                IconButton(icon: const Icon(Icons.router_rounded), tooltip: 'Bộ điều khiển trung tâm', onPressed: () => _open(context, const GatewaysScreen())),
              IconButton(icon: const Icon(Icons.people_alt_rounded), tooltip: 'Thành viên', onPressed: () => _open(context, const MembersScreen())),
              const SizedBox(width: 4),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                if (m.error != null) _ErrorBanner(message: m.error!, onRetry: m.reload),
                _SummaryCard(
                  gatewayOnline: m.gatewayOnline,
                  online: onlineCount,
                  total: m.devices.length,
                  on: switchesOn,
                  alerts: alerts,
                ),
                if (!m.gatewayOnline && m.devices.isEmpty)
                  _EmptyBlock(
                    icon: Icons.router_outlined,
                    title: 'Chưa có bộ điều khiển trung tâm',
                    message: 'Kết nối Raspberry Pi (Zigbee2MQTT) để thiết bị tự xuất hiện ở đây.',
                    action: home.isAdmin ? FilledButton.icon(icon: const Icon(Icons.add_rounded), label: const Text('Thêm bộ điều khiển'), onPressed: () => _open(context, const GatewaysScreen())) : null,
                  ),
                if (sections.isEmpty && m.gatewayOnline)
                  const _EmptyBlock(
                    icon: Icons.devices_other_rounded,
                    title: 'Chưa có thiết bị',
                    message: 'Ghép thiết bị trong Zigbee2MQTT, chúng sẽ tự xuất hiện ở đây.',
                  ),
                for (final (room, list) in sections) _RoomSection(room: room, devices: list, canControl: home.canControl, isAdmin: home.isAdmin),
              ]),
            ),
          ),
        ]),
      ),
      floatingActionButton: home.isAdmin
          ? FloatingActionButton.extended(
              backgroundColor: cs.primaryContainer,
              foregroundColor: cs.onPrimaryContainer,
              icon: const Icon(Icons.add_home_work_rounded),
              label: const Text('Thêm phòng'),
              onPressed: () => showRoomSheet(context, m),
            )
          : null,
    );
  }
}

// ───────────────────────── tổng quan ─────────────────────────

class _SummaryCard extends StatelessWidget {
  final bool gatewayOnline;
  final int online, total, on, alerts;
  const _SummaryCard({required this.gatewayOnline, required this.online, required this.total, required this.on, required this.alerts});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary, Color.lerp(cs.primary, const Color(0xFF0B5FA5), .55)!],
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .18), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(gatewayOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(gatewayOnline ? 'Đã kết nối' : 'Mất kết nối', style: tt.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          _Stat(value: '$on', label: 'Đang bật', icon: Icons.power_settings_new_rounded),
          _Stat(value: '$online/$total', label: 'Thiết bị online', icon: Icons.devices_rounded),
          _Stat(value: '$alerts', label: 'Cần chú ý', icon: Icons.notifications_active_rounded, highlight: alerts > 0),
        ]),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value, label;
  final IconData icon;
  final bool highlight;
  const _Stat({required this.value, required this.label, required this.icon, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: highlight ? const Color(0xFFFFD27A) : Colors.white.withValues(alpha: .85)),
        const SizedBox(height: 6),
        Text(value, style: tt.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
        Text(label, style: tt.labelSmall?.copyWith(color: Colors.white.withValues(alpha: .85))),
      ]),
    );
  }
}

// ───────────────────────── phòng & thiết bị ─────────────────────────

class _RoomSection extends StatelessWidget {
  final Room? room; // null = nhóm "Chưa phân phòng"
  final List<Device> devices;
  final bool canControl, isAdmin;
  const _RoomSection({required this.room, required this.devices, required this.canControl, required this.isAdmin});

  @override
  Widget build(BuildContext context) {
    final m = context.read<AppModel>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final onDevices = devices.where((d) => d.online && d.switchKeys.any(d.isOn)).toList();
    final canOff = canControl && m.gatewayOnline && onDevices.isNotEmpty;

    final title = room?.name ?? 'Chưa phân phòng';
    final icon = room?.kind.icon ?? Icons.help_outline_rounded;
    final onCount = onDevices.fold<int>(0, (n, d) => n + d.switchKeys.where(d.isOn).length);
    final editable = isAdmin && room != null;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 10),
        child: Row(children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: editable ? () => showRoomSheet(context, m, room: room) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: onCount > 0 ? cs.primary : cs.primaryContainer.withValues(alpha: .7),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(icon, size: 22, color: onCount > 0 ? cs.onPrimary : cs.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        '${devices.length} thiết bị${onCount > 0 ? ' · $onCount đang bật' : ''}',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ]),
                  ),
                  if (editable) Icon(Icons.edit_outlined, size: 18, color: cs.outline),
                ]),
              ),
            ),
          ),
          if (canOff)
            TextButton.icon(
              icon: const Icon(Icons.power_settings_new_rounded, size: 18),
              label: const Text('Tắt hết'),
              onPressed: () {
                HapticFeedback.mediumImpact();
                for (final d in onDevices) {
                  m.send(d, {for (final k in d.switchKeys.where(d.isOn)) k: 'OFF'});
                }
              },
            ),
        ]),
      ),
      if (devices.isEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text('Chưa có thiết bị trong phòng này. Bấm bút chì trên thiết bị để chuyển vào đây.', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ),
      for (final d in devices) Padding(padding: const EdgeInsets.only(bottom: 12), child: _DeviceCard(device: d, canControl: canControl, isAdmin: isAdmin)),
    ]);
  }
}

class _DeviceCard extends StatelessWidget {
  final Device device;
  final bool canControl, isAdmin;
  const _DeviceCard({required this.device, required this.canControl, required this.isAdmin});

  IconData get _icon => device.kind == 'light' ? Icons.lightbulb_rounded : (device.isSensor ? Icons.sensors_rounded : Icons.toggle_on_rounded);

  @override
  Widget build(BuildContext context) {
    final m = context.read<AppModel>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final d = device;
    final enabled = canControl && d.online && m.gatewayOnline;
    final anyOn = d.switchKeys.any(d.isOn);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: d.online ? 1 : .6,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onLongPress: isAdmin ? () => showDeviceEditDialog(context, m, d) : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: anyOn ? cs.primary : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_icon, color: anyOn ? cs.onPrimary : cs.onSurfaceVariant),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Row(children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: d.online ? const Color(0xFF2EBD6B) : cs.outline, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Flexible(child: Text('${d.typeLabel} · ${d.online ? 'Online' : 'Offline'}', overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
                    ]),
                  ]),
                ),
                if (isAdmin)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'Đổi tên / loại',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => showDeviceEditDialog(context, m, d),
                  ),
              ]),
              if (d.isSensor) ...[
                const SizedBox(height: 12),
                _tiles([for (final r in d.readings) _SensorTile(reading: r)]),
              ],
              if (d.switchKeys.isNotEmpty) ...[
                const SizedBox(height: 12),
                _tiles(
                  [
                    for (final key in d.switchKeys)
                      _ChannelTile(
                        icon: d.channelType(key).icon,
                        label: d.labelFor(key),
                        on: d.isOn(key),
                        enabled: enabled,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          m.send(d, {key: 'TOGGLE'});
                        },
                      ),
                  ],
                  columns: d.switchKeys.length == 1 ? 1 : 2,
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _tiles(List<Widget> children, {int columns = 2}) => LayoutBuilder(builder: (_, c) {
        const gap = 10.0;
        final w = (c.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final t in children) SizedBox(width: w, child: t)]);
      });
}

/// Ô điều khiển một gang: chạm để bật/tắt.
class _ChannelTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on, enabled;
  final VoidCallback onTap;
  const _ChannelTile({required this.icon, required this.label, required this.on, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final bg = on ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: .55);
    final fg = on ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1 : .55,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: enabled ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: on ? cs.primary : cs.surface, shape: BoxShape.circle),
                  child: Icon(icon, size: 20, color: on ? cs.onPrimary : cs.onSurfaceVariant),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                    Text(on ? 'Bật' : 'Tắt', style: tt.labelSmall?.copyWith(color: fg.withValues(alpha: .8))),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ô hiển thị số liệu cảm biến; nổi bật khi `alert`.
class _SensorTile extends StatelessWidget {
  final Reading reading;
  const _SensorTile({required this.reading});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final r = reading;
    final bg = r.alert ? cs.tertiaryContainer : cs.surfaceContainerHighest.withValues(alpha: .55);
    final fg = r.alert ? cs.onTertiaryContainer : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
      child: Row(children: [
        Icon(r.icon, size: 24, color: fg),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.label, style: tt.labelSmall?.copyWith(color: fg.withValues(alpha: .8))),
            Text(r.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
}

// ───────────────────────── thành phần phụ ─────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: TextStyle(color: cs.onErrorContainer))),
        TextButton(onPressed: onRetry, child: const Text('Thử lại')),
      ]),
    );
  }
}

class _EmptyBlock extends StatelessWidget {
  final IconData icon;
  final String title, message;
  final Widget? action;
  const _EmptyBlock({required this.icon, required this.title, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      child: Column(children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: .6), shape: BoxShape.circle),
          child: Icon(icon, size: 40, color: cs.primary),
        ),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(message, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ]),
    );
  }
}
