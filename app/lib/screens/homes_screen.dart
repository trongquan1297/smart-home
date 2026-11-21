import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../widgets/ui.dart';
import '../models.dart';

class HomesScreen extends StatelessWidget {
  const HomesScreen({super.key});

  Future<String?> _ask(BuildContext c, String title, String label) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: c,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
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

  /// Xoá tài khoản (App Store yêu cầu có ngay trong app): báo trước căn hộ nào bị xoá theo, bắt gõ "XOÁ" để xác nhận.
  Future<void> _deleteAccount(BuildContext c, AppModel m) async {
    final messenger = ScaffoldMessenger.of(c);
    List<dynamic> homes;
    try {
      homes = (await m.api.accountDeletionPreview())['homes'] as List<dynamic>? ?? [];
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      return;
    }
    if (!c.mounted) return;
    final ok = await showDialog<bool>(
      context: c,
      builder: (_) => _DeleteAccountDialog(homes: homes),
    );
    if (ok != true) return;
    try {
      await m.deleteAccount();
      messenger.showSnackBar(const SnackBar(content: Text('Đã xoá tài khoản.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  /// Khách thuê nhập mã: báo rõ đã nhận mã và khi nào được vào (đồng hồ đếm ngược hiện ở thẻ căn hộ).
  Future<void> _afterAccept(BuildContext c, Map<String, dynamic> r) async {
    if (r['role'] != 'renter' || r['valid_from'] == null) return;
    final from = DateTime.parse(r['valid_from']).toLocal();
    final until = r['valid_until'] == null ? null : DateTime.parse(r['valid_until']).toLocal();
    final waiting = from.isAfter(DateTime.now().add(const Duration(seconds: 2)));
    final stay = until == null ? '' : ' Thời gian sử dụng: ${fmtRemaining(until.difference(from))}.';
    await showDialog<void>(
      context: c,
      builder: (d) => AlertDialog(
        icon: IconBadge(waiting ? Icons.hourglass_top_rounded : Icons.check_circle_rounded, colors: waiting ? Vivid.timer : Vivid.power, size: 52),
        title: Text(waiting ? 'Đã nhận mã, đang đợi check-in' : 'Đã nhận quyền truy cập'),
        content: Text(
          waiting
              ? 'Bạn sẽ vào được căn hộ lúc ${fmtDateTime(from)} (còn ${fmtRemaining(from.difference(DateTime.now()))}). Thẻ căn hộ sẽ đếm ngược và tự mở khi tới giờ.$stay'
              : 'Bạn có thể bật/tắt thiết bị trong căn hộ${until == null ? '' : ' đến ${fmtDateTime(until)}'}.',
          textAlign: TextAlign.center,
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Đã hiểu'))],
      ),
    );
  }

  static String _roleLabel(String r) => switch (r) {
    'owner' => 'Chủ nhà',
    'admin' => 'Quản trị',
    'member' => 'Thành viên',
    'renter' => 'Khách thuê',
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
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              title: Text(name.isEmpty ? 'Căn hộ của tôi' : 'Xin chào, $name'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.group_add_rounded),
                  tooltip: 'Nhập mã mời',
                  onPressed: () async {
                    final t = await _ask(context, 'Nhập mã mời', 'Mã mời');
                    if (t != null && t.isNotEmpty && context.mounted) {
                      await _guard(context, () async {
                        final r = await m.api.acceptInvite(t);
                        await m.refreshHomes();
                        if (context.mounted) await _afterAccept(context, r);
                      });
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.add_home_rounded),
                  tooltip: 'Căn hộ mới',
                  onPressed: () async {
                    final n = await _ask(context, 'Căn hộ mới', 'Tên căn hộ');
                    if (n != null && n.isNotEmpty && context.mounted) await _guard(context, () => m.createFirstHome(n));
                  },
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.account_circle_rounded),
                  tooltip: 'Tài khoản',
                  onSelected: (v) {
                    if (v == 'logout') m.logout();
                    if (v == 'delete') _deleteAccount(context, m);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      enabled: false,
                      child: Text(
                        (m.me?['user']?['email'] ?? m.me?['email'] ?? '').toString(),
                        style: TextStyle(color: cs.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'logout',
                      child: ListTile(leading: Icon(Icons.logout_rounded), title: Text('Đăng xuất')),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete_forever_rounded, color: cs.error),
                        title: Text('Xoá tài khoản', style: TextStyle(color: cs.error)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (m.notice != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                sliver: SliverToBoxAdapter(
                  child: Card(
                    color: cs.tertiaryContainer,
                    child: ListTile(
                      leading: Icon(Icons.info_outline_rounded, color: cs.onTertiaryContainer),
                      title: Text(m.notice!, style: TextStyle(color: cs.onTertiaryContainer)),
                      trailing: IconButton(
                        icon: Icon(Icons.close_rounded, color: cs.onTertiaryContainer),
                        onPressed: m.clearNotice,
                      ),
                    ),
                  ),
                ),
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
                    if (h.isWaiting) return _WaitingCard(home: h);
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => m.selectHome(h),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              IconBadge(Icons.apartment_rounded, colors: h.isRenter ? Vivid.leave : const [Color(0xFF0EA5E9), Color(0xFF60A5FA)], size: 56),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(h.name, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        Pill(Icons.badge_rounded, _roleLabel(h.role), color: cs.primary),
                                        if (h.isRenter && h.accessUntil != null)
                                          Pill(Icons.timer_rounded, fmtDateTime(h.accessUntil!), color: Vivid.timer.last),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: m.isFavorite(h) ? 'Bỏ yêu thích' : 'Đặt làm căn hộ mặc định khi mở app',
                                onPressed: () => m.toggleFavorite(h),
                                icon: Icon(
                                  m.isFavorite(h) ? Icons.star_rounded : Icons.star_outline_rounded,
                                  color: m.isFavorite(h) ? const Color(0xFFF5A623) : cs.outline,
                                ),
                              ),
                              Icon(Icons.chevron_right_rounded, color: cs.outline),
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
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title, message;
  const _EmptyState({required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) => Center(
    child: EmptyState(icon: icon, colors: const [Color(0xFF0EA5E9), Color(0xFF60A5FA)], title: title, info: message),
  );
}

/// Khách thuê đã nhập mã nhưng chưa tới giờ check-in: thẻ đếm ngược, chưa vào được căn hộ.
class _WaitingCard extends StatelessWidget {
  final Home home;
  const _WaitingCard({required this.home});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final from = home.accessFrom, until = home.accessUntil;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Chưa tới giờ check-in. Căn hộ sẽ tự mở khi đồng hồ về 0.'))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IconBadge(Icons.hourglass_top_rounded, colors: Vivid.timer, size: 56),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(home.name, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(20)),
                          child: Text(
                            'Khách thuê · đang đợi check-in',
                            style: tt.labelSmall?.copyWith(color: cs.onTertiaryContainer, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (from != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .6), borderRadius: BorderRadius.circular(18)),
                  child: Column(
                    children: [
                      Text('Còn lại đến giờ check-in', style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      _CheckinCountdown(target: from),
                      const SizedBox(height: 6),
                      Text(
                        'Check-in lúc ${fmtDateTime(from)}${until == null ? '' : ' · dùng được ${fmtRemaining(until.difference(from))}'}',
                        textAlign: TextAlign.center,
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Đếm ngược từng giây. Về 0 thì hỏi lại máy chủ (mỗi 5 giây) cho tới khi máy chủ xác nhận đã kích hoạt:
/// máy chủ mới là nơi quyết định, đề phòng đồng hồ điện thoại lệch so với máy chủ.
class _CheckinCountdown extends StatefulWidget {
  final DateTime target;
  const _CheckinCountdown({required this.target});
  @override
  State<_CheckinCountdown> createState() => _CheckinCountdownState();
}

class _CheckinCountdownState extends State<_CheckinCountdown> {
  Timer? _t;
  DateTime _lastPoll = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      final now = DateTime.now();
      if (!now.isBefore(widget.target) && now.difference(_lastPoll) >= const Duration(seconds: 5)) {
        _lastPoll = now;
        context.read<AppModel>().refreshHomes().catchError((_) {});
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
    final left = widget.target.difference(DateTime.now());
    final started = left <= Duration.zero;
    return Text(
      started ? 'Đang kích hoạt…' : fmtCountdown(left),
      style: Theme.of(
        context,
      ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, color: cs.primary, fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}

/// Hộp xác nhận xoá tài khoản; tự giữ ô nhập (giải phóng khi hộp thoại thật sự rời cây widget, sau hiệu ứng đóng).
class _DeleteAccountDialog extends StatefulWidget {
  final List<dynamic> homes;
  const _DeleteAccountDialog({required this.homes});
  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  bool get _confirmed => const ['XOÁ', 'XÓA', 'XOA'].contains(_ctl.text.trim().toUpperCase());

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: cs.error),
      title: const Text('Xoá tài khoản vĩnh viễn?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Tài khoản, phiên đăng nhập, liên kết Google Home và Đăng nhập bằng Apple/Google của bạn sẽ bị xoá. Không thể hoàn tác.'),
            if (widget.homes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Các căn hộ bạn là người quản lý duy nhất cũng bị xoá cùng toàn bộ thiết bị, ngữ cảnh và bộ điều khiển:',
                style: TextStyle(color: cs.error, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              for (final h in widget.homes)
                Text('• ${h['name']}${(h['other_members'] ?? 0) > 0 ? ' (${h['other_members']} thành viên khác sẽ mất quyền)' : ''}'),
            ],
            const SizedBox(height: 14),
            const Text('Gõ XOÁ để xác nhận:'),
            const SizedBox(height: 6),
            TextField(
              controller: _ctl,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'XOÁ'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: _confirmed ? () => Navigator.pop(context, true) : null,
          child: const Text('Xoá tài khoản'),
        ),
      ],
    );
  }
}
