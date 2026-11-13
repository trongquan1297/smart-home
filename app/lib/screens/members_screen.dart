import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';

class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key});
  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  late Future<List<Member>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final m = context.read<AppModel>();
    _future = m.api.members(m.home!.id);
  }

  static String _roleLabel(String r) => switch (r) {
        'owner' => 'Chủ nhà',
        'admin' => 'Quản trị',
        'member' => 'Thành viên',
        _ => 'Khách',
      };

  static IconData _roleIcon(String r) => switch (r) {
        'owner' => Icons.workspace_premium_rounded,
        'admin' => Icons.admin_panel_settings_rounded,
        'member' => Icons.person_rounded,
        _ => Icons.visibility_rounded,
      };

  void _snack(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
  }

  Future<void> _invite() async {
    final m = context.read<AppModel>();
    final role = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Mời người thân tham gia', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Chọn quyền cho người được mời.', style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            _RoleOption(icon: Icons.person_rounded, title: 'Thành viên', subtitle: 'Xem và điều khiển thiết bị', onTap: () => Navigator.pop(c, 'member')),
            _RoleOption(icon: Icons.visibility_rounded, title: 'Khách', subtitle: 'Chỉ xem, không điều khiển', onTap: () => Navigator.pop(c, 'guest')),
            if (m.home!.role == 'owner')
              _RoleOption(icon: Icons.admin_panel_settings_rounded, title: 'Quản trị', subtitle: 'Quản lý phòng, thiết bị và thành viên', onTap: () => Navigator.pop(c, 'admin')),
          ]),
        ),
      ),
    );
    if (role == null || !mounted) return;
    try {
      final token = await m.api.invite(m.home!.id, role);
      if (!mounted) return;
      await _showToken(token, role);
    } catch (e) {
      _snack(e);
    }
  }

  Future<void> _showToken(String token, String role) {
    final cs = Theme.of(context).colorScheme;
    return showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Icons.mark_email_read_rounded, color: cs.primary, size: 32),
        title: const Text('Mã mời đã sẵn sàng'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Gửi mã này cho người thân. Họ mở app, bấm biểu tượng thêm người ở màn Căn hộ và nhập mã.\nQuyền: ${_roleLabel(role)} · hiệu lực 7 ngày · dùng 1 lần.',
              textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .6), borderRadius: BorderRadius.circular(14)),
            child: SelectableText(token, style: const TextStyle(fontFamily: 'Menlo', fontSize: 12.5)),
          ),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: token));
              Navigator.pop(c);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã sao chép mã mời')));
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Sao chép'),
          ),
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Xong')),
        ],
      ),
    );
  }

  Future<void> _remove(Member mem, bool self) async {
    final m = context.read<AppModel>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(self ? 'Rời căn hộ?' : 'Xoá thành viên?'),
        content: Text(self ? 'Bạn sẽ không còn truy cập căn hộ này cho tới khi được mời lại.' : 'Xoá ${mem.name} khỏi căn hộ. Họ sẽ mất quyền truy cập ngay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: Text(self ? 'Rời' : 'Xoá'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await m.api.removeMember(m.home!.id, mem.userId);
      if (self) {
        await m.refreshHomes();
        m.leaveHome();
        if (mounted) Navigator.pop(context);
      } else {
        setState(_load);
      }
    } catch (e) {
      _snack(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final home = m.home!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => setState(_load),
        child: CustomScrollView(slivers: [
          const SliverAppBar.large(title: Text('Thành viên')),
          FutureBuilder<List<Member>>(
            future: _future,
            builder: (_, snap) {
              if (snap.hasError) return SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('${snap.error}')));
              if (!snap.hasData) return const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()));
              final list = snap.data!;
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                sliver: SliverList.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final mem = list[i];
                    final self = mem.userId == m.me?['id'];
                    final canRemove = mem.role != 'owner' && (self || home.isAdmin);
                    final initials = mem.name.trim().isEmpty ? '?' : mem.name.trim().split(RegExp(r'\s+')).map((w) => w[0]).take(2).join().toUpperCase();
                    final owner = mem.role == 'owner';
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(children: [
                          CircleAvatar(
                            radius: 26,
                            backgroundColor: owner ? cs.primary : cs.secondaryContainer,
                            child: Text(initials, style: TextStyle(fontWeight: FontWeight.w800, color: owner ? cs.onPrimary : cs.onSecondaryContainer)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Flexible(child: Text(mem.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
                                if (self) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                                    decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(10)),
                                    child: Text('Bạn', style: tt.labelSmall?.copyWith(color: cs.onTertiaryContainer, fontWeight: FontWeight.w700)),
                                  ),
                                ],
                              ]),
                              Text(mem.email, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: .7), borderRadius: BorderRadius.circular(20)),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(_roleIcon(mem.role), size: 14, color: cs.onPrimaryContainer),
                                  const SizedBox(width: 4),
                                  Text(_roleLabel(mem.role), style: tt.labelSmall?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
                                ]),
                              ),
                            ]),
                          ),
                          if (canRemove)
                            IconButton(
                              tooltip: self ? 'Rời căn hộ' : 'Xoá thành viên',
                              icon: Icon(self ? Icons.logout_rounded : Icons.person_remove_rounded, color: cs.error),
                              onPressed: () => _remove(mem, self),
                            ),
                        ]),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ]),
      ),
      floatingActionButton: home.isAdmin
          ? FloatingActionButton.extended(onPressed: _invite, icon: const Icon(Icons.person_add_alt_1_rounded), label: const Text('Mời thành viên'))
          : null,
    );
  }
}

class _RoleOption extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const _RoleOption({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: cs.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.outline),
            ]),
          ),
        ),
      ),
    );
  }
}
