import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';

/// Lịch sử cảnh báo cảm biến của căn hộ (30 ngày gần nhất, tối đa 50 dòng). Chỉ thành viên trở lên xem được.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<List<AppNotification>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  late final AppModel _model = context.read<AppModel>();

  void _load() {
    _model.notificationsOpen = true;
    _future = _model.api.notifications(_model.home!.id).then((l) {
      _model.markNotificationsSeen(l.isEmpty ? null : l.first.createdAt);
      return l;
    });
  }

  @override
  void dispose() {
    _model.notificationsOpen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Thông báo')),
      body: RefreshIndicator(
        onRefresh: () async => setState(_load),
        child: FutureBuilder<List<AppNotification>>(
          future: _future,
          builder: (_, snap) {
            if (snap.hasError) {
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('${snap.error}', textAlign: TextAlign.center),
                  ),
                ],
              );
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) {
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 96, 32, 0),
                    child: Column(
                      children: [
                        Icon(Icons.notifications_none_rounded, size: 56, color: cs.primary.withValues(alpha: .6)),
                        const SizedBox(height: 16),
                        Text('Chưa có cảnh báo nào', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                          'Mở một ngữ cảnh như "Đi vắng" có chọn cảm biến cảnh báo. Khi cảm biến hiện diện hoặc cửa được kích hoạt, thông báo sẽ hiện ở đây.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final n = list[i];
                final icon = switch (n.kind) {
                  'door_open' => Icons.door_front_door_outlined,
                  'scene_auto' => Icons.auto_awesome_rounded,
                  'scene_failed' => Icons.error_outline_rounded,
                  _ => Icons.directions_walk_rounded,
                };
                return Card(
                  child: ListTile(
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(14)),
                      child: Icon(icon, color: cs.onTertiaryContainer),
                    ),
                    title: Text(n.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${n.body}\n${fmtDateTime(n.createdAt)}'),
                    isThreeLine: true,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
