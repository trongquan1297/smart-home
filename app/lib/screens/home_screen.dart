import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';
import 'cameras_screen.dart';
import 'purifier_screen.dart';
import 'device_edit_dialog.dart';
import '../widgets/ui.dart';
import 'device_rules_sheet.dart';
import 'gateways_screen.dart';
import 'matter_screen.dart';
import 'notifications_screen.dart';
import 'pair_device_sheet.dart';
import 'scenes_screen.dart';
import 'members_screen.dart';
import 'room_sheet.dart';
import 'speakers_screen.dart';

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
    final picked = await showCenterSheet<Scene>(
      context: context,
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
                  leading: IconBadge(s.kind.icon, colors: sceneColors(s.kind.id), size: 40),
                  title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
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

  /// Một nút + cho mọi loại thiết bị: hỏi loại trước (Zigbee / camera), rồi mở luồng thêm tương ứng.
  Future<void> _addDevice(BuildContext context) async {
    final kind = await showCenterSheet<String>(context: context, builder: (c) => const _AddKindSheet());
    if (kind == null || !context.mounted) return;
    if (kind == 'camera') return showAddCameraSheet(context);
    if (kind == 'purifier') return showAddPurifierSheet(context);
    if (!context.read<AppModel>().gatewayOnline) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bộ điều khiển trung tâm đang offline: cần online mới ghép được thiết bị')));
      return;
    }
    showPairDeviceSheet(context);
  }

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
                // Ghép thiết bị Zigbee mới ngay trong app (không cần mở giao diện web của Zigbee2MQTT).
                if (home.isAdmin)
                  IconButton(
                    icon: Icon(Icons.add_rounded, size: 28, color: cs.primary),
                    tooltip: 'Thêm thiết bị',
                    onPressed: () => _addDevice(context),
                  ),
                // Khách thuê chỉ bật/tắt thiết bị: không có ngữ cảnh, danh sách thành viên.
                if (home.canRunScenes)
                  IconButton(
                    icon: const Icon(Icons.auto_awesome_rounded, color: Color(0xFF8B5CF6)),
                    tooltip: 'Ngữ cảnh',
                    onPressed: () => _open(context, const ScenesScreen()),
                  ),
                // Khách thuê chỉ bật/tắt thiết bị; khách xem không có thông báo (máy chủ không gửi cảnh báo cho họ).
                if (home.canRunScenes)
                  IconButton(
                    icon: Badge(
                      isLabelVisible: m.unreadAlerts > 0,
                      label: Text(m.unreadAlerts > 9 ? '9+' : '${m.unreadAlerts}'),
                      child: const Icon(Icons.notifications_rounded, color: Color(0xFFF59E0B)),
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
                      'cameras' => const CamerasScreen(),
                      'matter' => const MatterScreen(),
                      'speakers' => const SpeakersScreen(),
                      _ => const GatewaysScreen(),
                    }),
                    itemBuilder: (_) => [
                      if (home.canRunScenes)
                        const PopupMenuItem(
                          value: 'cameras',
                          child: ListTile(
                            leading: IconBadge(Icons.videocam_rounded, colors: Vivid.info, size: 32),
                            title: Text('Camera'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      const PopupMenuItem(
                        value: 'members',
                        child: ListTile(
                          leading: IconBadge(Icons.people_alt_rounded, colors: Vivid.members, size: 32),
                          title: Text('Thành viên'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      if (home.isAdmin) ...const [
                        PopupMenuItem(
                          value: 'matter',
                          child: ListTile(
                            leading: IconBadge(Icons.qr_code_2_rounded, colors: Vivid.matter, size: 32),
                            title: Text('Google Home / Apple Home'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'speakers',
                          child: ListTile(
                            leading: IconBadge(Icons.speaker_rounded, colors: Vivid.speak, size: 32),
                            title: Text('Loa thông báo'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'gateways',
                          child: ListTile(
                            leading: IconBadge(Icons.router_rounded, colors: Vivid.gateway, size: 32),
                            title: Text('Bộ điều khiển trung tâm'),
                            contentPadding: EdgeInsets.zero,
                          ),
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
                  _SummaryCard(
                    gatewayOnline: m.gatewayOnline,
                    online: onlineCount,
                    total: m.devices.length,
                    on: switchesOn,
                    scene: home.canRunScenes ? m.activeScene : null,
                    showScene: home.canRunScenes,
                    onPickScene: () => _pickScene(context),
                    onDisarm: m.disarm,
                  ),
                  if (m.cameras.isNotEmpty) _CameraStrip(cameras: m.cameras, onAll: () => _open(context, const CamerasScreen())),
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
                    _EmptyBlock(
                      icon: Icons.devices_other_rounded,
                      title: 'Chưa có thiết bị',
                      message: 'Bấm "Thêm thiết bị" rồi đưa thiết bị Zigbee về chế độ ghép nối.',
                      action: home.isAdmin
                          ? FilledButton.icon(icon: const Icon(Icons.add_rounded), label: const Text('Thêm thiết bị'), onPressed: () => _addDevice(context))
                          : null,
                    ),
                ]),
              ),
            ),
            // Thanh tab các phòng (ghim dưới thanh tiêu đề khi cuộn).
            // Quản trị viên luôn thấy thanh tab để có nút thêm phòng ở cuối.
            if (!noDevicesAnywhere || home.isAdmin)
              SliverPersistentHeader(
                pinned: true,
                delegate: _RoomTabsHeader(
                  tabs: tabs,
                  selected: selected,
                  background: Theme.of(context).scaffoldBackgroundColor,
                  onSelect: (k) => setState(() => _tab = k),
                  onAdd: home.isAdmin ? () => showRoomSheet(context, m) : null,
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
    );
  }
}

/// Căn hộ có ngữ cảnh "Tự chuyển khi rời nhà" nhưng điện thoại này chưa cho phép vị trí "Luôn luôn".
class _LocationBanner extends StatelessWidget {
  final Future<void> Function() onTap;
  const _LocationBanner({required this.onTap});

  @override
  Widget build(BuildContext context) => _Banner(
    icon: Icons.location_disabled_rounded,
    colors: Vivid.leave,
    title: 'Cần quyền vị trí',
    info: 'Căn hộ có ngữ cảnh "Tự chuyển khi rời nhà". Cho phép vị trí "Luôn luôn" để điện thoại này báo khi bạn rời nhà, kể cả khi app đã đóng.',
    action: FilledButton.tonal(onPressed: onTap, child: const Text('Cho phép')),
  );
}

/// Dải thông báo gọn: biểu tượng màu + tiêu đề ngắn + "i" + nút.
class _Banner extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final String title;
  final String? info;
  final Widget? action;
  const _Banner({required this.icon, required this.colors, required this.title, this.info, this.action});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(colors: [colors.first.withValues(alpha: .14), colors.last.withValues(alpha: .08)]),
        border: Border.all(color: colors.first.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          IconBadge(icon, colors: colors, size: 38),
          const SizedBox(width: 10),
          Flexible(
            child: Text(title, style: tt.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          if (info != null) InfoTip(title, info!),
          const Spacer(),
          ?action,
        ],
      ),
    );
  }
}

/// Chế độ cảnh báo đang bật (ngữ cảnh chạy gần nhất có chọn cảm biến): nhắc người dùng và cho tắt nhanh.
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
    final left = widget.until.difference(DateTime.now());
    final soon = left < const Duration(hours: 1);
    return _Banner(
      icon: Icons.timer_rounded,
      colors: soon ? Vivid.danger : Vivid.timer,
      title: 'Còn ${fmtRemaining(left)}',
      info: 'Quyền khách thuê hết lúc ${fmtDateTime(widget.until)}. Bạn chỉ bật/tắt được thiết bị.',
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
  final VoidCallback? onAdd; // null = không có quyền thêm phòng
  const _RoomTabsHeader({required this.tabs, required this.selected, required this.background, required this.onSelect, this.onAdd});

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
        itemCount: tabs.length + (onAdd == null ? 0 : 1),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          if (i == tabs.length) {
            // Nút thêm phòng: tab cuối cùng, viền màu chủ đạo.
            return Tooltip(
              message: 'Thêm phòng',
              child: Material(
                color: cs.primaryContainer,
                shape: StadiumBorder(side: BorderSide(color: cs.primary.withValues(alpha: .5))),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onAdd,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Icon(Icons.add_rounded, color: cs.primary),
                  ),
                ),
              ),
            );
          }
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
  final Future<void> Function() onDisarm; // tắt ngữ cảnh đang bật (ngừng canh cảm biến)
  const _SummaryCard({
    required this.gatewayOnline,
    required this.online,
    required this.total,
    required this.on,
    required this.scene,
    required this.showScene,
    required this.onPickScene,
    required this.onDisarm,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    // Màu thẻ đổi theo ngữ cảnh đang bật; chưa có ngữ cảnh thì dùng màu chủ đạo.
    final base = scene != null ? sceneColors(scene!.kind.id) : [cs.primary, Color.lerp(cs.primary, const Color(0xFF60A5FA), .6)!];
    final colors = [Color.lerp(base.first, Colors.black, .0)!, Color.lerp(base.last, Colors.black, .08)!];

    Widget circle(double size, double alpha) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: alpha),
      ),
    );

    final status = Semantics(
      label: gatewayOnline ? 'Đã kết nối' : 'Mất kết nối',
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(gatewayOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, size: 24, color: Colors.white),
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: gatewayOnline ? const Color(0xFF4ADE80) : const Color(0xFFF87171),
                  border: Border.all(color: colors.last, width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final sceneRow = Row(
      children: [
        Icon(scene?.kind.icon ?? Icons.auto_awesome_rounded, color: Colors.white, size: 34),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                scene?.name ?? 'Chọn ngữ cảnh',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tt.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: -.3),
              ),
              if (scene != null && scene!.alertDevices.isNotEmpty)
                Text(
                  'Đang canh ${scene!.alertDevices.length} cảm biến',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodySmall?.copyWith(color: Colors.white.withValues(alpha: .9)),
                ),
            ],
          ),
        ),
        if (scene != null) _SceneSwitch(sceneName: scene!.name, onOff: onDisarm),
        const SizedBox(width: 4),
        status,
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        boxShadow: [BoxShadow(color: colors.last.withValues(alpha: .35), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Stack(
        children: [
          Positioned(top: -50, right: -30, child: circle(150, .10)),
          Positioned(bottom: -70, left: -40, child: circle(160, .07)),
          Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Chỉ hiện hàng ngữ cảnh khi đang có ngữ cảnh được kích hoạt.
                  if (showScene && scene != null) ...[
                    Semantics(
                      button: true,
                      label: 'Ngữ cảnh: ${scene!.name}',
                      child: InkWell(borderRadius: BorderRadius.circular(18), onTap: onPickScene, child: sceneRow),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      _Stat(value: '$on', label: 'Đang bật', icon: Icons.power_settings_new_rounded),
                      const SizedBox(width: 10),
                      _Stat(value: '$online/$total', label: 'Thiết bị online', icon: Icons.wifi_rounded, progress: total == 0 ? null : online / total),
                      if (!(showScene && scene != null)) ...[const SizedBox(width: 10), status],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Công tắc gạt cạnh tên ngữ cảnh đang bật: gạt tắt = ngừng ngữ cảnh (và ngừng canh cảm biến của nó).
class _SceneSwitch extends StatefulWidget {
  final String sceneName;
  final Future<void> Function() onOff;
  const _SceneSwitch({required this.sceneName, required this.onOff});
  @override
  State<_SceneSwitch> createState() => _SceneSwitchState();
}

class _SceneSwitchState extends State<_SceneSwitch> {
  bool _busy = false;

  Future<void> _off() async {
    final msg = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onOff();
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Tắt ngữ cảnh ${widget.sceneName}',
    child: Switch(
      value: !_busy, // gạt xong hiện tắt ngay trong lúc chờ máy chủ
      onChanged: _busy ? null : (v) => v ? null : _off(),
      activeThumbColor: Colors.white,
      activeTrackColor: Colors.white.withValues(alpha: .35),
      inactiveThumbColor: Colors.white,
      inactiveTrackColor: Colors.white.withValues(alpha: .15),
      trackOutlineColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: .5)),
    ),
  );
}

class _Stat extends StatelessWidget {
  final String value, label;
  final IconData icon;
  final double? progress;
  const _Stat({required this.value, required this.label, required this.icon, this.progress});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Expanded(
      child: Semantics(
        label: '$label: $value', // không hiện chữ nhưng đọc được bằng trình đọc màn hình
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
            decoration: BoxDecoration(color: const Color(0x29FFFFFF), borderRadius: BorderRadius.circular(18)),
            child: Row(
              children: [
                Icon(icon, size: 26, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          value,
                          style: tt.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800, height: 1.1),
                        ),
                      ),
                      if (progress != null) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            color: Colors.white,
                            backgroundColor: Colors.white.withValues(alpha: .22),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
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
                        IconBadge(icon, colors: roomColors(room?.kind.id), size: 42),
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
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  Pill(Icons.devices_rounded, '${devices.length}'),
                                  if (onCount > 0) ...[const SizedBox(width: 6), Pill(Icons.power_settings_new_rounded, '$onCount', color: cs.primary)],
                                ],
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
                IconButton.filledTonal(
                  icon: const Icon(Icons.power_settings_new_rounded),
                  tooltip: 'Tắt hết',
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
            child: Row(
              children: [
                Pill(Icons.inbox_rounded, 'Trống'),
                InfoTip('Phòng trống', 'Bấm biểu tượng bút chì trên một thiết bị để chuyển thiết bị vào phòng này.'),
              ],
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
    if (d.isPurifier) return Icons.water_drop_rounded;
    if (d.isCover) return Icons.window_rounded;
    if (d.isPlug) return Icons.power_rounded;
    return d.isSensor ? Icons.sensors_rounded : Icons.toggle_on_rounded;
  }

  List<Color> get _colors {
    final d = device;
    if (d.kind == 'light') return const [Color(0xFFFBBF24), Color(0xFFF97316)];
    if (d.isPurifier) return Vivid.water;
    if (d.isCover) return const [Color(0xFF3B82F6), Color(0xFF06B6D4)];
    if (d.isPlug) return Vivid.power;
    if (d.isSensor) return const [Color(0xFF8B5CF6), Color(0xFF6366F1)];
    return Vivid.device;
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
          onTap: d.isPurifier ? () => openPurifier(context, d) : null,
          onLongPress: isAdmin ? () => showDeviceEditDialog(context, m, d) : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: IconBadge(_icon, key: ValueKey(anyOn), colors: _colors, size: 46, muted: !anyOn && !d.isSensor && !d.isPurifier),
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
                    if (isAdmin && d.switchKeys.isNotEmpty)
                      IconButton(
                        icon: Badge(isLabelVisible: m.rules.any((r) => r.deviceId == d.id), smallSize: 8, child: const Icon(Icons.bolt_rounded, size: 22)),
                        tooltip: 'Tự động hoá',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => showDeviceRulesSheet(context, m, d),
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
                if (d.isPurifier) ...[
                  const SizedBox(height: 12),
                  PurifierSummary(device: d),
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
                  IconBadge(icon, colors: Vivid.device, size: 34, muted: !on),
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
  Widget build(BuildContext context) => EmptyState(icon: icon, colors: Vivid.gateway, title: title, info: message, action: action);
}

/// Dải camera ngang trên màn hình căn hộ: chạm để xem trực tiếp.
class _CameraStrip extends StatelessWidget {
  final List<Camera> cameras;
  final VoidCallback onAll;
  const _CameraStrip({required this.cameras, required this.onAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            icon: Icons.videocam_rounded,
            colors: Vivid.info,
            title: 'Camera',
            trailing: TextButton(onPressed: onAll, child: const Text('Tất cả')),
          ),
          SizedBox(
            height: 128,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cameras.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final c = cameras[i];
                return SizedBox(
                  width: 192,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => openCamera(context, c),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CameraThumb(camera: c),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.circle, size: 8, color: c.online ? const Color(0xFF22C55E) : const Color(0xFFEF4444)),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      c.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Chọn loại thiết bị cần thêm. Sau này thêm loại mới (addon khác) chỉ cần thêm một dòng ở đây.
class _AddKindSheet extends StatelessWidget {
  const _AddKindSheet();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    Widget option(String value, IconData icon, List<Color> colors, String title, String sub) => Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: IconBadge(icon, colors: colors, size: 40),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.pop(context, value),
      ),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Thêm thiết bị', style: tt.titleLarge),
            const SizedBox(height: 16),
            option('zigbee', Icons.toggle_on_rounded, Vivid.device, 'Thiết bị Zigbee', 'Công tắc, ổ cắm, rèm, cảm biến…'),
            option('camera', Icons.videocam_rounded, Vivid.info, 'Camera', 'Camera Wi‑Fi ONVIF / RTSP'),
            option('purifier', Icons.water_drop_rounded, Vivid.water, 'Máy lọc nước', 'Karofi có Bluetooth: TDS, tuổi thọ lõi lọc'),
          ],
        ),
      ),
    );
  }
}
