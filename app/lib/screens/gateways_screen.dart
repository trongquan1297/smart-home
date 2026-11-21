import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../widgets/ui.dart';

/// Quản lý bộ điều khiển trung tâm (Raspberry Pi chạy Zigbee2MQTT) của căn hộ. Chỉ admin/owner.
class GatewaysScreen extends StatefulWidget {
  const GatewaysScreen({super.key});
  @override
  State<GatewaysScreen> createState() => _GatewaysScreenState();
}

class _GatewaysScreenState extends State<GatewaysScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final m = context.read<AppModel>();
    _future = m.api.gateways(m.home!.id);
  }

  String _seen(String? iso) {
    if (iso == null) return 'Chưa từng kết nối';
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Lần cuối ${two(t.hour)}:${two(t.minute)} · ${two(t.day)}/${two(t.month)}/${t.year}';
  }

  void _snack(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
  }

  Future<bool> _confirm(String title, String body, String action, {bool danger = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(
          danger ? Icons.warning_amber_rounded : Icons.vpn_key_rounded,
          color: danger ? Theme.of(c).colorScheme.error : Theme.of(c).colorScheme.primary,
          size: 32,
        ),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
            onPressed: () => Navigator.pop(c, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _add() async {
    final m = context.read<AppModel>();
    final ctl = TextEditingController(text: 'Raspberry Pi');
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Icons.router_rounded, color: Theme.of(c).colorScheme.primary, size: 32),
        title: const Text('Thêm bộ điều khiển'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Tên gợi nhớ', hintText: 'vd: Pi tầng 1'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Tạo')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final token = await m.api.createGateway(m.home!.id, name);
      if (!mounted) return;
      setState(_load);
      await _showToken(m.api.gatewayWsUrl, token);
    } catch (e) {
      _snack(e);
    }
  }

  Future<void> _showToken(String wsUrl, String token) {
    final env = 'CLOUD_WS_URL=$wsUrl\nGATEWAY_TOKEN=$token';
    return showCenterSheet<void>(
      context: context,
      barrierDismissible: false,
      topPadding: 0,
      builder: (c) {
        final cs = Theme.of(c).colorScheme;
        final tt = Theme.of(c).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const IconBadge(Icons.vpn_key_rounded, colors: Vivid.timer, size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text('Mã kết nối', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _Step(n: 1, text: 'Sao chép 2 dòng dưới đây.'),
                _Step(n: 2, text: 'Dán vào file .env trên Raspberry Pi (thư mục edge/).'),
                _Step(n: 3, text: 'Chạy docker compose up -d. Thiết bị sẽ tự xuất hiện.'),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .6), borderRadius: BorderRadius.circular(16)),
                  child: SelectableText(env, style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Pill(Icons.visibility_off_rounded, 'Chỉ hiện một lần', color: cs.error),
                    const InfoTip(
                      'Giữ bí mật mã này',
                      'Mã chỉ hiện một lần và không xem lại được. Mất mã thì chọn "Đổi mã kết nối". Không chia sẻ cho người khác: ai có mã đều kết nối được vào căn hộ.',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: env));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã sao chép')));
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Sao chép'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Đã lưu mã')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _rotate(Map<String, dynamic> g) async {
    final ok = await _confirm(
      'Đổi mã kết nối?',
      'Mã cũ của "${g['name']}" bị vô hiệu ngay và Pi đang dùng mã cũ sẽ bị ngắt kết nối cho tới khi bạn cập nhật mã mới. '
          'Thiết bị, phòng và tên được giữ nguyên. Dùng khi nghi ngờ lộ mã.',
      'Đổi mã',
    );
    if (!ok || !mounted) return;
    final m = context.read<AppModel>();
    try {
      final token = await m.api.rotateGateway(g['id'] as String);
      if (!mounted) return;
      setState(_load);
      await _showToken(m.api.gatewayWsUrl, token);
    } catch (e) {
      _snack(e);
    }
  }

  Future<void> _delete(Map<String, dynamic> g) async {
    final n = g['device_count'] ?? 0;
    final ok = await _confirm(
      'Xoá bộ điều khiển?',
      'Xoá "${g['name']}" và $n thiết bị của nó (kèm tên, phòng, cài đặt gang). Không thể hoàn tác. '
          'Mã kết nối của nó ngừng hoạt động ngay. Nếu chỉ nghi ngờ lộ mã, hãy chọn "Đổi mã kết nối" để giữ thiết bị.',
      'Xoá',
      danger: true,
    );
    if (!ok || !mounted) return;
    final m = context.read<AppModel>();
    try {
      await m.api.deleteGateway(g['id'] as String);
      await m.reload();
      if (mounted) setState(_load);
    } catch (e) {
      _snack(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => setState(_load),
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              title: const Text('Bộ điều khiển'),
              actions: [
                IconButton(icon: const Icon(Icons.add_rounded), tooltip: 'Thêm bộ điều khiển', onPressed: _add),
                const SizedBox(width: 8),
              ],
            ),
            FutureBuilder<Map<String, dynamic>>(
              future: _future,
              builder: (_, snap) {
                if (snap.hasError) return SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('${snap.error}')));
                if (!snap.hasData) return const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()));
                final online = snap.data!['online'] == true;
                final list = (snap.data!['gateways'] as List).cast<Map<String, dynamic>>();
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: online ? [cs.primary, Color.lerp(cs.primary, const Color(0xFF60A5FA), .55)!] : [cs.outline, cs.outlineVariant],
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(width: 52, child: Icon(online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, color: Colors.white, size: 40)),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    online ? 'Đang kết nối' : 'Chưa kết nối',
                                    style: tt.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                                  ),
                                  Text(m.home!.name, style: tt.bodySmall?.copyWith(color: Colors.white.withValues(alpha: .85))),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      if (list.isEmpty)
                        const EmptyState(
                          icon: Icons.router_rounded,
                          colors: Vivid.gateway,
                          title: 'Chưa có bộ điều khiển',
                          info:
                              'Bấm "Thêm" để tạo mã kết nối cho Raspberry Pi (Zigbee2MQTT) hoặc cho máy chạy gateway loa. Thiết bị sẽ tự xuất hiện sau khi bộ điều khiển kết nối.',
                        ),
                      for (final g in list)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                              child: Row(
                                children: [
                                  IconBadge(Icons.router_rounded, colors: Vivid.gateway, size: 48, muted: g['online'] != true),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          g['name'] as String,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                        ),
                                        const SizedBox(height: 3),
                                        Row(
                                          children: [
                                            Container(
                                              width: 8,
                                              height: 8,
                                              decoration: BoxDecoration(
                                                color: g['online'] == true ? const Color(0xFF2EBD6B) : cs.outline,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                '${g['online'] == true ? 'Đang kết nối' : _seen(g['last_seen_at'] as String?)} · ${g['device_count'] ?? 0} thiết bị',
                                                overflow: TextOverflow.ellipsis,
                                                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    tooltip: 'Tuỳ chọn',
                                    onSelected: (v) => v == 'rotate' ? _rotate(g) : _delete(g),
                                    itemBuilder: (_) => [
                                      const PopupMenuItem(
                                        value: 'rotate',
                                        child: ListTile(leading: Icon(Icons.vpn_key_rounded), title: Text('Đổi mã kết nối'), contentPadding: EdgeInsets.zero),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: ListTile(
                                          leading: Icon(Icons.delete_outline_rounded, color: cs.error),
                                          title: Text('Xoá bộ điều khiển', style: TextStyle(color: cs.error)),
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                );
              },
            ),
          ],
        ),
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
            child: Text(
              '$n',
              style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
