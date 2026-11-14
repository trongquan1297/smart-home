import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';
import 'device_edit_dialog.dart';
import 'gateways_screen.dart';
import 'matter_screen.dart';
import 'notifications_screen.dart';
import 'scenes_screen.dart';
import 'members_screen.dart';
import 'room_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Khoá của tab: 'all' = tất cả, 'none' = chưa phân phòng, còn lại là id phòng.
class _HomeScreenState extends State<HomeScreen> {
  String _tab = 'all';

  /// Bảng chọn ngữ cảnh: chạm một ngữ cảnh để kích hoạt (chạy ngay và thành ngữ cảnh đang bật).
  Future<void> _pickScene(BuildContext context) async {
    final m = context.read<AppModel>();
    final msg = ScaffoldMessenger.of(context);
    final picked = await showModalBottomSheet<Scene>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final scenes = m.scenes;
        if (scenes.isEmpty) {
          return const Padding(padding: EdgeInsets.fromLTRB(24, 8, 24, 32), child: Text('Chưa có ngữ cảnh nào. Tạo ở ✨ Ngữ cảnh.'));
        }
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final s in scenes)
                ListTile(
                  leading: Icon(s.kind.icon),
                  title: Text(s.name),
                  subtitle: Text('${s.actions.length} thiết bị${s.alertDevices.isNotEmpty ? ' · cảnh báo ${s.alertDevices.length} cảm biến' : ''}'),
                  trailing: s.active ? Icon(Icons.check_circle_rounded, color: Theme.of(ctx).colorScheme.primary) : null,
                  selected: s.active,
                  onTap: () => Navigator.pop(ctx, s),
                ),
            ],
          ),
        );
      },
    );
    if (picked == null || picked.active) return;
    try {
      final r = await m.runScene(picked);
      msg.showSnackBar(
        SnackBar(content: Text(r['sent'] == r['total'] ? 'Đã bật "${picked.name}"' : 'Đã gửi ${r['sent']}/${r['total']} lệnh của "${picked.name}"')),
      );
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(e.toString().contains('gateway offline') ? 'Bộ điều khiển trung tâm đang offline' : e.toString())));
    }
  }

  void _open(BuildContext context, Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    // AnimatedSwitcher giữ trang cũ thêm 250 ms khi rời căn hộ: lúc đó home đã null, đừng dựng gì cả.
    final home = m.home;
    if (home == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    // Nhóm thiết bị theo phòng; thiết bị chưa gán phòng vào "Chưa phân phòng".
    final groups = <String?, List<Device>>{};
    for (final d in m.devices) {
      groups.putIfAbsent(d.roomId, () => []).add(d);
    }
    final unassigned = groups[null] ?? const <Device>[];
    final tabs = <_TabInfo>[
      _TabInfo('all', 'Tất cả', Icons.dashboard_rounded, m.devices.length),
      for (final r in m.rooms) _TabInfo(r.id, r.name, r.kind.icon, (groups[r.id] ?? const []).length),
      if (unassigned.isNotEmpty) _TabInfo('none', 'Chưa phân phòng', Icons.help_outline_rounded, unassigned.length),
    ];
    // Phòng đang chọn bị xoá / hết thiết bị chưa phân phòng → quay về "Tất cả".
    final selected = tabs.any((t) => t.key == _tab) ? _tab : 'all';

    // Nội dung theo tab đang chọn.
    final sections = <(Room?, List<Device>)>[
      if (selected == 'all') ...[
        for (final r in m.rooms) (r, groups[r.id] ?? const <Device>[]),
        if (unassigned.isNotEmpty) (null, unassigned),
      ] else if (selected == 'none')
        (null, unassigned)
      else
        for (final r in m.rooms.where((r) => r.id == selected)) (r, groups[r.id] ?? const <Device>[]),
    ];

    final switchesOn = m.devices.fold<int>(0, (n, d) => n + d.switchKeys.where(d.isOn).length);
    final onlineCount = m.devices.where((d) => d.online).length;
    final noDevicesAnywhere = m.devices.isEmpty && m.rooms.isEmpty;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: m.reload,
        child: CustomScrollView(
          slivers: [
            // Tên căn hộ nằm ngay cạnh nút quay lại.
            SliverAppBar(
              pinned: true,
              titleSpacing: 0,
              leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: m.leaveHome),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      home.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  // Ngôi sao: đặt/bỏ căn hộ yêu thích (mở app sẽ vào thẳng căn hộ này).
                  InkResponse(
                    radius: 20,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      m.toggleFavorite(home);
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text(m.isFavorite(home) ? 'Đã đặt "${home.name}" làm căn hộ mặc định' : 'Đã bỏ căn hộ mặc định')));
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(
                        m.isFavorite(home) ? Icons.star_rounded : Icons.star_outline_rounded,
                        size: 22,
                        color: m.isFavorite(home) ? const Color(0xFFF5A623) : cs.outline,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                // Khách thuê chỉ bật/tắt thiết bị: không có ngữ cảnh, danh sách thành viên.
                if (home.canRunScenes)
                  IconButton(icon: const Icon(Icons.auto_awesome_rounded), tooltip: 'Ngữ cảnh', onPressed: () => _open(context, const ScenesScreen())),
                // Khách thuê chỉ bật/tắt thiết bị; khách xem không có thông báo (máy chủ không gửi cảnh báo cho họ).
                if (home.canRunScenes)
                  IconButton(
                    icon: Badge(
                      isLabelVisible: m.unreadAlerts > 0,
                      label: Text(m.unreadAlerts > 9 ? '9+' : '${m.unreadAlerts}'),
                      child: const Icon(Icons.notifications_rounded),
                    ),
                    tooltip: 'Thông báo',
                    onPressed: () => _open(context, const NotificationsScreen()),
                  ),
                // Thành viên + công cụ quản trị ít dùng nằm trong menu để tên căn hộ có chỗ hiển thị.
                if (!home.isRenter)
                  PopupMenuButton<String>(
                    tooltip: 'Thêm',
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (v) => _open(context, switch (v) {
                      'members' => const MembersScreen(),
                      'matter' => const MatterScreen(),
                      _ => const GatewaysScreen(),
                    }),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'members',
                        child: ListTile(leading: Icon(Icons.people_alt_rounded), title: Text('Thành viên'), contentPadding: EdgeInsets.zero),
                      ),
                      if (home.isAdmin) ...const [
                        PopupMenuItem(
                          value: 'matter',
                          child: ListTile(leading: Icon(Icons.qr_code_2_rounded), title: Text('Google Home / Apple Home'), contentPadding: EdgeInsets.zero),
                        ),
                        PopupMenuItem(
                          value: 'gateways',
                          child: ListTile(leading: Icon(Icons.router_rounded), title: Text('Bộ điều khiển trung tâm'), contentPadding: EdgeInsets.zero),
                        ),
                      ],
                    ],
                  ),
                const SizedBox(width: 4),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (m.error != null) _ErrorBanner(message: m.error!, onRetry: m.reload),
                  if (home.isRenter && home.accessUntil != null) _RenterBanner(until: home.accessUntil!),
                  if (m.needsLocationPermission) _LocationBanner(onTap: m.enableLocationTracking),
                  if (home.canRunScenes && m.activeScene != null && m.activeScene!.alertDevices.isNotEmpty) _ModeBanner(scene: m.activeScene!, onOff: m.disarm),
                  _SummaryCard(
                    gatewayOnline: m.gatewayOnline,
                    online: onlineCount,
                    total: m.devices.length,
                    on: switchesOn,
                    scene: home.canRunScenes ? m.activeScene : null,
                    showScene: home.canRunScenes,
                    onPickScene: () => _pickScene(context),
                  ),
                  if (!m.gatewayOnline && m.devices.isEmpty)
                    _EmptyBlock(
                      icon: Icons.router_outlined,
                      title: 'Chưa có bộ điều khiển trung tâm',
                      message: 'Kết nối Raspberry Pi (Zigbee2MQTT) để thiết bị tự xuất hiện ở đây.',
                      action: home.isAdmin
                          ? FilledButton.icon(
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('Thêm bộ điều khiển'),
                              onPressed: () => _open(context, const GatewaysScreen()),
                            )
                          : null,
                    ),
                  if (noDevicesAnywhere && m.gatewayOnline)
                    const _EmptyBlock(
                      icon: Icons.devices_other_rounded,
                      title: 'Chưa có thiết bị',
                      message: 'Ghép thiết bị trong Zigbee2MQTT, chúng sẽ tự xuất hiện ở đây.',
                    ),
                ]),
              ),
            ),
            // Thanh tab các phòng (ghim dưới thanh tiêu đề khi cuộn).
            if (!noDevicesAnywhere)
              SliverPersistentHeader(
                pinned: true,
                delegate: _RoomTabsHeader(
                  tabs: tabs,
                  selected: selected,
                  background: Theme.of(context).scaffoldBackgroundColor,
                  onSelect: (k) => setState(() => _tab = k),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  for (final (room, list) in sections)
                    _RoomSection(key: ValueKey('${room?.id}-$selected'), room: room, devices: list, canControl: home.canControl, isAdmin: home.isAdmin),
                ]),
              ),
            ),
          ],
        ),
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

/// Căn hộ có ngữ cảnh "Tự chuyển khi rời nhà" nhưng điện thoại này chưa cho phép vị trí "Luôn luôn".
class _LocationBanner extends StatelessWidget {
  final Future<void> Function() onTap;
  const _LocationBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(18)),
      child: Row(
        children: [
          Icon(Icons.location_off_rounded, color: cs.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Cho phép vị trí "Luôn luôn" để ngữ cảnh tự chạy khi bạn rời nhà',
              style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: onTap, child: const Text('Cho phép')),
        ],
      ),
    );
  }
}

/// Chế độ cảnh báo đang bật (ngữ cảnh chạy gần nhất có chọn cảm biến): nhắc người dùng và cho tắt nhanh.
class _ModeBanner extends StatelessWidget {
  final Scene scene;
  final Future<void> Function() onOff;
  const _ModeBanner({required this.scene, required this.onOff});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(18)),
      child: Row(
        children: [
          Icon(scene.kind.icon, color: cs.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Chế độ "${scene.name}" đang bật · cảnh báo ${scene.alertDevices.length} cảm biến',
              style: TextStyle(color: cs.onTertiaryContainer, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () async {
              final msg = ScaffoldMessenger.of(context);
              try {
                await onOff();
              } catch (e) {
                msg.showSnackBar(SnackBar(content: Text(e.toString())));
              }
            },
            child: const Text('Tắt'),
          ),
        ],
      ),
    );
  }
}

/// Khách thuê: hiện thời gian còn lại, và tự thoát khi hết hạn (phòng khi mất kết nối WebSocket).
class _RenterBanner extends StatefulWidget {
  final DateTime until;
  const _RenterBanner({required this.until});
  @override
  State<_RenterBanner> createState() => _RenterBannerState();
}

class _RenterBannerState extends State<_RenterBanner> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      if (!DateTime.now().isBefore(widget.until)) {
        context.read<AppModel>().accessEnded();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final left = widget.until.difference(DateTime.now());
    final soon = left < const Duration(hours: 1);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: soon ? cs.errorContainer : cs.secondaryContainer, borderRadius: BorderRadius.circular(18)),
      child: Row(
        children: [
          Icon(Icons.timer_outlined, color: soon ? cs.onErrorContainer : cs.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Quyền khách thuê còn ${fmtRemaining(left)} · hết lúc ${fmtDateTime(widget.until)}. Bạn chỉ bật/tắt được thiết bị.',
              style: TextStyle(color: soon ? cs.onErrorContainer : cs.onSecondaryContainer, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabInfo {
  final String key, label;
  final IconData icon;
  final int count;
  const _TabInfo(this.key, this.label, this.icon, this.count);
}

/// Thanh tab cuộn ngang: mỗi tab là icon + tên phòng; chạm để xem thiết bị của phòng đó.
class _RoomTabsHeader extends SliverPersistentHeaderDelegate {
  final List<_TabInfo> tabs;
  final String selected;
  final Color background;
  final ValueChanged<String> onSelect;
  const _RoomTabsHeader({required this.tabs, required this.selected, required this.background, required this.onSelect});

  static const _height = 62.0;
  @override
  double get minExtent => _height;
  @override
  double get maxExtent => _height;

  @override
  bool shouldRebuild(covariant _RoomTabsHeader old) => true;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: background,
      alignment: Alignment.center,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final t = tabs[i];
          final on = t.key == selected;
          final fg = on ? cs.onPrimary : cs.onSurfaceVariant;
          return Semantics(
            button: true,
            selected: on,
            label: '${t.label}, ${t.count} thiết bị',
            child: Material(
              color: on ? cs.primary : cs.surfaceContainerHighest.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () {
                  HapticFeedback.selectionClick();
                  onSelect(t.key);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(t.icon, size: 20, color: fg),
                      const SizedBox(width: 8),
                      Text(
                        t.label,
                        style: TextStyle(color: fg, fontWeight: on ? FontWeight.w700 : FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ───────────────────────── tổng quan ─────────────────────────

class _SummaryCard extends StatelessWidget {
  final bool gatewayOnline;
  final int online, total, on;
  final Scene? scene; // ngữ cảnh đang được kích hoạt
  final bool showScene;
  final VoidCallback onPickScene;
  const _SummaryCard({
    required this.gatewayOnline,
    required this.online,
    required this.total,
    required this.on,
    required this.scene,
    required this.showScene,
    required this.onPickScene,
  });

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: .18), borderRadius: BorderRadius.circular(20)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(gatewayOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      gatewayOnline ? 'Đã kết nối' : 'Mất kết nối',
                      style: tt.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _Stat(value: '$on', label: 'Đang bật', icon: Icons.power_settings_new_rounded),
              _Stat(value: '$online/$total', label: 'Thiết bị online', icon: Icons.devices_rounded),
              if (showScene)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: onPickScene,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(scene?.kind.icon ?? Icons.auto_awesome_rounded, size: 18, color: Colors.white.withValues(alpha: .85)),
                        const SizedBox(height: 6),
                        // Cùng cỡ chữ với các số ở hai ô bên cạnh; tên dài thì thu nhỏ cho vừa ô.
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            scene?.name ?? 'Chưa chọn',
                            maxLines: 1,
                            style: tt.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value, label;
  final IconData icon;
  const _Stat({required this.value, required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Expanded(
      child: Semantics(
        label: '$label: $value', // không hiện chữ nhưng đọc được bằng trình đọc màn hình
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: Colors.white.withValues(alpha: .85)),
              const SizedBox(height: 6),
              Text(
                value,
                style: tt.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── phòng & thiết bị ─────────────────────────

class _RoomSection extends StatelessWidget {
  final Room? room; // null = nhóm "Chưa phân phòng"
  final List<Device> devices;
  final bool canControl, isAdmin;
  const _RoomSection({super.key, required this.room, required this.devices, required this.canControl, required this.isAdmin});

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 10),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: editable ? () => showRoomSheet(context, m, room: room) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    child: Row(
                      children: [
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              Text(
                                '${devices.length} thiết bị${onCount > 0 ? ' · $onCount đang bật' : ''}',
                                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        if (editable) Icon(Icons.edit_outlined, size: 18, color: cs.outline),
                      ],
                    ),
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
            ],
          ),
        ),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Chưa có thiết bị trong phòng này. Bấm bút chì trên thiết bị để chuyển vào đây.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        for (final d in devices)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _DeviceCard(device: d, canControl: canControl, isAdmin: isAdmin),
          ),
      ],
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final Device device;
  final bool canControl, isAdmin;
  const _DeviceCard({required this.device, required this.canControl, required this.isAdmin});

  IconData get _icon {
    final d = device;
    if (d.kind == 'light') return Icons.lightbulb_rounded;
    if (d.isCover) return Icons.window_rounded;
    if (d.isPlug) return Icons.power_rounded;
    return d.isSensor ? Icons.sensors_rounded : Icons.toggle_on_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final m = context.read<AppModel>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final d = device;
    final enabled = canControl && d.online && m.gatewayOnline;
    final anyOn = d.switchKeys.any(d.isOn) || (d.isCover && ((d.state['position'] as num?) ?? 0) > 0);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: d.online ? 1 : .6,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onLongPress: isAdmin ? () => showDeviceEditDialog(context, m, d) : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: anyOn ? cs.primary : cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
                      child: Icon(_icon, color: anyOn ? cs.onPrimary : cs.onSurfaceVariant),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(color: d.online ? const Color(0xFF2EBD6B) : cs.outline, shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  '${(d.vendor ?? '').isNotEmpty ? '${d.vendor} · ' : ''}${d.typeLabel}${d.online ? '' : ' · Offline'}',
                                  overflow: TextOverflow.ellipsis,
                                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (isAdmin)
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: 'Đổi tên / loại',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => showDeviceEditDialog(context, m, d),
                      ),
                  ],
                ),
                if (d.switchKeys.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _tiles([
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
                  ], columns: d.switchKeys.length == 1 ? 1 : 2),
                ],
                if (d.isCover) ...[
                  const SizedBox(height: 12),
                  _CoverControls(key: ValueKey('cover-${d.id}'), device: d, enabled: enabled, allowPosition: !(m.home?.isRenter ?? false)),
                ],
                if (d.readings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _tiles([for (final r in d.readings) _SensorTile(reading: r)]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tiles(List<Widget> children, {int columns = 2}) => LayoutBuilder(
    builder: (_, c) {
      const gap = 10.0;
      final w = (c.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in children) SizedBox(width: w, child: t)],
      );
    },
  );
}

/// Điều khiển rèm / cửa cuốn: Mở · Dừng · Đóng và thanh trượt vị trí (nếu thiết bị báo `position`).
class _CoverControls extends StatefulWidget {
  final Device device;
  final bool enabled;
  final bool allowPosition; // khách thuê chỉ Mở/Đóng/Dừng, không đặt vị trí
  const _CoverControls({super.key, required this.device, required this.enabled, this.allowPosition = true});
  @override
  State<_CoverControls> createState() => _CoverControlsState();
}

class _CoverControlsState extends State<_CoverControls> {
  double? _drag; // đang kéo: hiện giá trị kéo thay vì giá trị thiết bị báo

  @override
  Widget build(BuildContext context) {
    final m = context.read<AppModel>();
    final d = widget.device;
    final cs = Theme.of(context).colorScheme;
    final reported = (d.state['position'] as num?)?.toDouble();
    final value = (_drag ?? reported ?? 0).clamp(0, 100).toDouble();
    Widget btn(IconData icon, String label, String state) => Expanded(
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 8)),
        onPressed: widget.enabled
            ? () {
                HapticFeedback.lightImpact();
                m.send(d, {'state': state});
              }
            : null,
        icon: Icon(icon, size: 20),
        label: Text(label),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            btn(Icons.keyboard_arrow_up_rounded, 'Mở', 'OPEN'),
            const SizedBox(width: 8),
            btn(Icons.stop_rounded, 'Dừng', 'STOP'),
            const SizedBox(width: 8),
            btn(Icons.keyboard_arrow_down_rounded, 'Đóng', 'CLOSE'),
          ],
        ),
        if (d.hasPosition && widget.allowPosition) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Text(reported == null && _drag == null ? 'Vị trí: chưa rõ' : 'Mở ${value.round()}%', style: TextStyle(color: cs.onSurfaceVariant)),
              Expanded(
                child: Slider(
                  value: value,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  onChanged: widget.enabled ? (v) => setState(() => _drag = v) : null,
                  onChangeEnd: widget.enabled
                      ? (v) {
                          m.send(d, {'position': v.round()});
                          setState(() => _drag = null);
                        }
                      : null,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
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
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: on ? cs.primary : cs.surface, shape: BoxShape.circle),
                    child: Icon(icon, size: 20, color: on ? cs.onPrimary : cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w700),
                        ),
                        Text(on ? 'Bật' : 'Tắt', style: tt.labelSmall?.copyWith(color: fg.withValues(alpha: .8))),
                      ],
                    ),
                  ),
                ],
              ),
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
      child: Row(
        children: [
          Icon(r.icon, size: 24, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.label, style: tt.labelSmall?.copyWith(color: fg.withValues(alpha: .8))),
                Text(
                  r.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
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
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: cs.onErrorContainer)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Thử lại')),
        ],
      ),
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
      child: Column(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: .6), shape: BoxShape.circle),
            child: Icon(icon, size: 40, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
