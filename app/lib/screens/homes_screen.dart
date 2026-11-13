import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';

class HomesScreen extends StatelessWidget {
  const HomesScreen({super.key});

  Future<String?> _ask(BuildContext c, String title, String label) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: c,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _guard(BuildContext c, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  static String _roleLabel(String r) => switch (r) {
        'owner' => 'Chủ nhà',
        'admin' => 'Quản trị',
        'member' => 'Thành viên',
        _ => 'Khách',
      };

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final name = (m.me?['name'] as String?)?.trim() ?? '';

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: m.refreshHomes,
        child: CustomScrollView(slivers: [
          SliverAppBar.large(
            title: Text(name.isEmpty ? 'Căn hộ của tôi' : 'Xin chào, $name'),
            actions: [IconButton(icon: const Icon(Icons.logout_rounded), tooltip: 'Đăng xuất', onPressed: m.logout)],
          ),
          if (m.homes.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(
                icon: Icons.apartment_rounded,
                title: 'Chưa có căn hộ nào',
                message: 'Tạo căn hộ mới, hoặc nhập mã mời để tham gia căn hộ của gia đình.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              sliver: SliverList.separated(
                itemCount: m.homes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final Home h = m.homes[i];
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => m.selectHome(h),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              gradient: LinearGradient(colors: [cs.primary, cs.tertiary]),
                            ),
                            child: Icon(Icons.apartment_rounded, color: cs.onPrimary, size: 28),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(h.name, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(20)),
                                child: Text(_roleLabel(h.role),
                                    style: tt.labelSmall?.copyWith(color: cs.onSecondaryContainer, fontWeight: FontWeight.w600)),
                              ),
                            ]),
                          ),
                          Icon(Icons.chevron_right_rounded, color: cs.outline),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
        ]),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        FloatingActionButton.small(
          heroTag: 'join',
          tooltip: 'Nhập mã mời',
          backgroundColor: cs.secondaryContainer,
          foregroundColor: cs.onSecondaryContainer,
          onPressed: () async {
            final t = await _ask(context, 'Nhập mã mời', 'Mã mời');
            if (t != null && t.isNotEmpty && context.mounted) {
              await _guard(context, () async {
                await m.api.acceptInvite(t);
                await m.refreshHomes();
              });
            }
          },
          child: const Icon(Icons.group_add_rounded),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.extended(
          heroTag: 'new',
          icon: const Icon(Icons.add_rounded),
          label: const Text('Căn hộ mới'),
          onPressed: () async {
            final n = await _ask(context, 'Căn hộ mới', 'Tên căn hộ');
            if (n != null && n.isNotEmpty && context.mounted) await _guard(context, () => m.createFirstHome(n));
          },
        ),
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title, message;
  const _EmptyState({required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: .6), shape: BoxShape.circle),
          child: Icon(icon, size: 44, color: cs.primary),
        ),
        const SizedBox(height: 20),
        Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
      ]),
    );
  }
}
