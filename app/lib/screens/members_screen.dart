import 'dart:async';

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
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    // Làm mới thời gian còn lại của khách thuê (chỉ vẽ lại, không gọi mạng).
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _load() {
    final m = context.read<AppModel>();
    _future = m.api.members(m.home!.id);
  }

  static String _roleLabel(String r) => switch (r) {
    'owner' => 'Chủ nhà',
    'admin' => 'Quản trị',
    'member' => 'Thành viên',
    'renter' => 'Khách thuê',
    _ => 'Khách',
  };

  static IconData _roleIcon(String r) => switch (r) {
    'owner' => Icons.workspace_premium_rounded,
    'admin' => Icons.admin_panel_settings_rounded,
    'member' => Icons.person_rounded,
    'renter' => Icons.key_rounded,
    _ => Icons.visibility_rounded,
  };

  void _snack(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
  }

  Future<void> _invite() async {
    final m = context.read<AppModel>();
    final role = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true, // 4 lựa chọn có thể cao hơn nửa màn hình nhỏ: cho cuộn thay vì tràn
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Mời người thân tham gia', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Chọn quyền cho người được mời.', style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 14),
              _RoleOption(icon: Icons.person_rounded, title: 'Thành viên', subtitle: 'Xem và điều khiển thiết bị', onTap: () => Navigator.pop(c, 'member')),
              _RoleOption(
                icon: Icons.key_rounded,
                title: 'Khách thuê',
                subtitle: 'Chỉ bật/tắt thiết bị, có giới hạn thời gian sử dụng',
                onTap: () => Navigator.pop(c, 'renter'),
              ),
              _RoleOption(icon: Icons.visibility_rounded, title: 'Khách', subtitle: 'Chỉ xem, không điều khiển', onTap: () => Navigator.pop(c, 'guest')),
              if (m.home!.role == 'owner')
                _RoleOption(
                  icon: Icons.admin_panel_settings_rounded,
                  title: 'Quản trị',
                  subtitle: 'Quản lý phòng, thiết bị và thành viên',
                  onTap: () => Navigator.pop(c, 'admin'),
                ),
            ],
          ),
        ),
      ),
    );
    if (role == null || !mounted) return;
    try {
      _RenterTerms? terms;
      if (role == 'renter') {
        terms = await showModalBottomSheet<_RenterTerms>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => const _RenterInviteSheet(),
        );
        if (terms == null || !mounted) return;
      }
      final token = await m.api.invite(m.home!.id, role, durationHours: terms?.hours, startsAt: terms?.startsAt);
      if (!mounted) return;
      await _showToken(token, role, terms: terms);
    } catch (e) {
      _snack(e);
    }
  }

  Future<void> _showToken(String token, String role, {_RenterTerms? terms}) {
    final cs = Theme.of(context).colorScheme;
    return showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Icons.mark_email_read_rounded, color: cs.primary, size: 32),
        title: const Text('Mã mời đã sẵn sàng'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Gửi mã này cho người thân. Họ mở app, bấm biểu tượng thêm người ở màn Căn hộ và nhập mã.\nQuyền: ${_roleLabel(role)} · mã có hiệu lực 7 ngày · dùng 1 lần.${terms == null ? '' : '\n${terms.describe()}'}',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .6), borderRadius: BorderRadius.circular(14)),
              child: SelectableText(token, style: const TextStyle(fontFamily: 'Menlo', fontSize: 12.5)),
            ),
          ],
        ),
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
        title: Text(self ? 'Rời căn hộ?' : (mem.isRenter ? 'Thu hồi quyền ngay?' : 'Xoá thành viên?')),
        content: Text(
          self
              ? 'Bạn sẽ không còn truy cập căn hộ này cho tới khi được mời lại.'
              : (mem.isRenter
                    ? 'Thu hồi quyền của ${mem.name}. Họ bị ngắt khỏi căn hộ ngay lập tức, kể cả khi đang mở app.'
                    : 'Xoá ${mem.name} khỏi căn hộ. Họ sẽ mất quyền truy cập ngay.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: Text(self ? 'Rời' : (mem.isRenter ? 'Thu hồi ngay' : 'Xoá')),
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

  /// Trạng thái khách thuê tính theo đồng hồ máy (cập nhật mỗi 30 giây không cần gọi mạng).
  static String _renterStatus(Member mem) {
    final from = mem.validFrom, until = mem.validUntil;
    if (from == null || until == null) return 'expired';
    final now = DateTime.now();
    if (now.isBefore(from)) return 'scheduled';
    if (!now.isBefore(until)) return 'expired';
    return 'active';
  }

  Future<void> _grantNow(Member mem) async {
    final m = context.read<AppModel>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cấp quyền ngay?'),
        content: Text('${mem.name} sẽ truy cập được ngay bây giờ và được dùng đủ ${mem.durationHours ?? 0} giờ kể từ lúc này.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cấp ngay')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await m.api.memberAction(m.home!.id, mem.userId, 'grant_now');
      setState(_load);
    } catch (e) {
      _snack(e);
    }
  }

  Future<void> _extend(Member mem) async {
    final m = context.read<AppModel>();
    final hours = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Gia hạn cho ${mem.name}', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Cộng thêm thời gian sử dụng.', style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (h, label) in [(1, '+1 giờ'), (6, '+6 giờ'), (12, '+12 giờ'), (24, '+1 ngày'), (72, '+3 ngày'), (168, '+7 ngày')])
                    ActionChip(label: Text(label), onPressed: () => Navigator.pop(c, h)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (hours == null || !mounted) return;
    try {
      await m.api.memberAction(m.home!.id, mem.userId, 'extend', hours: hours);
      setState(_load);
    } catch (e) {
      _snack(e);
    }
  }

  Widget _renterPanel(Member mem, ColorScheme cs, TextTheme tt) {
    final st = _renterStatus(mem);
    final until = mem.validUntil, from = mem.validFrom;
    final (IconData icon, String text, Color color) = switch (st) {
      'active' => (Icons.timer_outlined, 'Đang hoạt động · còn ${fmtRemaining(until!.difference(DateTime.now()))} (đến ${fmtDateTime(until)})', cs.primary),
      'scheduled' => (Icons.schedule_rounded, 'Chưa bắt đầu · từ ${fmtDateTime(from!)} (${mem.durationHours} giờ)', cs.tertiary),
      _ => (Icons.timer_off_outlined, 'Đã hết hạn${until == null ? '' : ' lúc ${fmtDateTime(until)}'}', cs.error),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: tt.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (st != 'active')
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 36), visualDensity: VisualDensity.compact),
                  onPressed: () => _grantNow(mem),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Cấp quyền ngay'),
                ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36), visualDensity: VisualDensity.compact),
                onPressed: () => _extend(mem),
                icon: const Icon(Icons.more_time_rounded, size: 18),
                label: const Text('Gia hạn'),
              ),
            ],
          ),
        ],
      ),
    );
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
        child: CustomScrollView(
          slivers: [
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
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 26,
                                backgroundColor: owner ? cs.primary : cs.secondaryContainer,
                                child: Text(
                                  initials,
                                  style: TextStyle(fontWeight: FontWeight.w800, color: owner ? cs.onPrimary : cs.onSecondaryContainer),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            mem.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                        if (self) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                                            decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(10)),
                                            child: Text(
                                              'Bạn',
                                              style: tt.labelSmall?.copyWith(color: cs.onTertiaryContainer, fontWeight: FontWeight.w700),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    Text(
                                      mem.email,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                    ),
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                      decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: .7), borderRadius: BorderRadius.circular(20)),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(_roleIcon(mem.role), size: 14, color: cs.onPrimaryContainer),
                                          const SizedBox(width: 4),
                                          Text(
                                            _roleLabel(mem.role),
                                            style: tt.labelSmall?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (mem.isRenter) _renterPanel(mem, cs, tt),
                                  ],
                                ),
                              ),
                              if (canRemove)
                                IconButton(
                                  tooltip: self ? 'Rời căn hộ' : (mem.isRenter ? 'Thu hồi ngay' : 'Xoá thành viên'),
                                  icon: Icon(self ? Icons.logout_rounded : Icons.person_remove_rounded, color: cs.error),
                                  onPressed: () => _remove(mem, self),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
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
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(14)),
                  child: Icon(icon, color: cs.onPrimaryContainer),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: cs.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Điều khoản mời khách thuê: số giờ sử dụng và (tuỳ chọn) giờ bắt đầu.
class _RenterTerms {
  final int hours;
  final DateTime? startsAt; // null = tính từ lúc khách nhập mã
  const _RenterTerms(this.hours, this.startsAt);

  String describe() {
    final h = hours % 24 == 0 && hours >= 24 ? '${hours ~/ 24} ngày' : '$hours giờ';
    final start = startsAt == null ? 'tính từ lúc khách nhập mã' : 'bắt đầu lúc ${fmtDateTime(startsAt!)}';
    return 'Khách thuê dùng được $h, $start. Chỉ bật/tắt thiết bị.';
  }
}

class _RenterInviteSheet extends StatefulWidget {
  const _RenterInviteSheet();
  @override
  State<_RenterInviteSheet> createState() => _RenterInviteSheetState();
}

class _RenterInviteSheetState extends State<_RenterInviteSheet> {
  static const _presets = [(6, '6 giờ'), (12, '12 giờ'), (24, '1 ngày'), (72, '3 ngày'), (168, '7 ngày'), (720, '30 ngày')];
  int _hours = 24;
  final _custom = TextEditingController();
  bool _scheduled = false;
  DateTime _start = DateTime.now().add(const Duration(hours: 1));
  String? _error;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(context: context, initialDate: _start, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: w!),
    );
    if (t == null) return;
    setState(() => _start = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  void _submit() {
    final typed = int.tryParse(_custom.text.trim());
    final hours = _custom.text.trim().isEmpty ? _hours : typed;
    if (hours == null || hours < 1 || hours > 8760) {
      setState(() => _error = 'Số giờ phải từ 1 đến 8760 (1 năm)');
      return;
    }
    if (_scheduled && _start.isBefore(DateTime.now())) {
      setState(() => _error = 'Giờ bắt đầu phải ở tương lai');
      return;
    }
    Navigator.pop(context, _RenterTerms(hours, _scheduled ? _start : null));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Mời khách thuê', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'Khách chỉ bật/tắt được thiết bị và tự mất quyền khi hết giờ. Bạn có thể cấp ngay, gia hạn hoặc thu hồi bất cứ lúc nào.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Text('Thời gian sử dụng', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (h, label) in _presets)
                    ChoiceChip(
                      showCheckmark: false,
                      label: Text(label),
                      selected: _custom.text.trim().isEmpty && _hours == h,
                      onSelected: (_) => setState(() {
                        _hours = h;
                        _custom.clear();
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _custom,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Hoặc nhập số giờ', hintText: 'vd: 48', suffixText: 'giờ'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              Text('Bắt đầu', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Khi khách nhập mã')),
                  ButtonSegment(value: true, label: Text('Hẹn giờ')),
                ],
                selected: {_scheduled},
                onSelectionChanged: (s) => setState(() => _scheduled = s.first),
              ),
              if (_scheduled) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _pickStart,
                  icon: const Icon(Icons.event_rounded),
                  label: Text('Bắt đầu lúc ${fmtDateTime(_start)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                ),
                const SizedBox(height: 6),
                Text(
                  'Trước giờ này khách chưa vào được; bạn có thể bấm "Cấp quyền ngay" để mở sớm.',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, style: TextStyle(color: cs.error)),
                ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _submit, child: const Text('Tạo mã mời')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
