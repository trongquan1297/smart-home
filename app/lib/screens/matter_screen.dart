import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api.dart';
import '../app_model.dart';
import '../models.dart';

/// Kết nối Google Home / Apple Home qua Matter: hiện mã QR để quét trong Home app.
/// Matter chạy trên mạng LAN của nhà nên bridge nằm trên Pi; mã chỉ đi qua gateway, không lưu trên cloud.
class MatterScreen extends StatefulWidget {
  const MatterScreen({super.key});
  @override
  State<MatterScreen> createState() => _MatterScreenState();
}

class _MatterScreenState extends State<MatterScreen> {
  MatterInfo? _info;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // Tự cập nhật để thấy ngay khi Home app ghép xong.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy && !_loading) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<MatterInfo> Function(Api api, String homeId) call, {bool silent = false}) async {
    final m = context.read<AppModel>();
    if (!silent) setState(() => _busy = true);
    try {
      final info = await call(m.api, m.home!.id);
      if (!mounted) return;
      setState(() {
        _info = info;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent || _info == null) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _busy = false;
        });
      }
    }
  }

  Future<void> _load({bool silent = false}) => _run((api, id) => api.matterInfo(id), silent: silent);

  Future<void> _setPairing(bool open) => _run((api, id) => api.matterPairing(id, open));

  Future<void> _remove(MatterFabric f) async {
    final name = f.label.isNotEmpty ? f.label : (f.vendor.isNotEmpty ? f.vendor : 'ứng dụng này');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Icons.link_off_rounded, color: Theme.of(c).colorScheme.error, size: 32),
        title: const Text('Ngắt kết nối?'),
        content: Text('"$name" sẽ mất quyền xem và điều khiển các thiết bị của căn hộ. Bạn có thể ghép lại sau.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Ngắt kết nối'),
          ),
        ],
      ),
    );
    if (ok == true) await _run((api, id) => api.matterRemoveFabric(id, f.index));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            const SliverAppBar.large(title: Text('Google Home · Apple Home')),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
              sliver: SliverList(delegate: SliverChildListDelegate(_body(context))),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final info = _info;
    if (_loading && info == null) {
      return const [
        Padding(
          padding: EdgeInsets.only(top: 80),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (info == null) {
      return [
        _Notice(
          icon: Icons.cloud_off_rounded,
          title: 'Chưa lấy được thông tin',
          message: _error ?? 'Thử lại sau.',
          action: FilledButton(onPressed: _load, child: const Text('Thử lại')),
        ),
      ];
    }
    if (!info.available) {
      return const [
        _Notice(
          icon: Icons.hub_outlined,
          title: 'Bộ cầu nối Matter chưa bật',
          message: 'Bật dịch vụ Matterbridge trên Raspberry Pi (xem README, mục Matter) rồi quay lại đây.',
        ),
      ];
    }

    final showQr = info.pairingOpen && info.qr != null;
    return [
      _StatusCard(info: info),
      const SizedBox(height: 14),
      if (_error != null)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(14)),
          child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
        ),
      if (showQr) _QrCard(info: info, onClose: info.commissioned && !_busy ? () => _setPairing(false) : null),
      if (!showQr)
        FilledButton.icon(
          onPressed: _busy ? null : () => _setPairing(true),
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2)) : const Icon(Icons.qr_code_2_rounded),
          label: const Text('Thêm ứng dụng khác (hiện mã QR)'),
        ),
      if (info.fabrics.isNotEmpty) ...[
        const SizedBox(height: 22),
        Text('Đang kết nối', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final f in info.fabrics)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(14)),
                child: Icon(Icons.smartphone_rounded, color: cs.onPrimaryContainer),
              ),
              title: Text(f.vendor.isNotEmpty ? f.vendor : 'Ứng dụng Matter', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(f.label.isNotEmpty ? f.label : 'Fabric #${f.index}'),
              trailing: IconButton(
                tooltip: 'Ngắt kết nối',
                icon: Icon(Icons.link_off_rounded, color: cs.error),
                onPressed: _busy ? null : () => _remove(f),
              ),
            ),
          ),
      ],
      const SizedBox(height: 22),
      Text('Hướng dẫn', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const _Guide(
        icon: Icons.home_rounded,
        title: 'Apple Home (iPhone)',
        steps: [
          'Mở ứng dụng Nhà (Home) → bấm + → Thêm phụ kiện.',
          'Quét mã QR ở trên (hoặc chọn "Thêm theo cách thủ công" rồi nhập mã số).',
          'Chọn phòng và đặt tên cho các thiết bị rồi hoàn tất.',
        ],
      ),
      const _Guide(
        icon: Icons.assistant_rounded,
        title: 'Google Home (Android / iPhone)',
        steps: [
          'Mở ứng dụng Google Home → bấm + → Thiết lập thiết bị.',
          'Chọn thiết bị tương thích Matter (Matter-enabled device).',
          'Quét mã QR ở trên (hoặc nhập mã số), làm theo hướng dẫn.',
        ],
      ),
      const SizedBox(height: 6),
      _Hint(
        icon: Icons.wifi_rounded,
        text:
            'Khi ghép, điện thoại và Raspberry Pi phải cùng mạng Wi‑Fi/LAN. Google Home thường yêu cầu một thiết bị trung tâm Matter của Google trong nhà (loa/màn hình Nest hoặc Google TV tương thích) cùng mạng để thiết lập và điều khiển; nếu thấy thông báo "Bạn cần có một thiết bị trung tâm chuẩn Matter" thì đó là điều kiện của Google Home, không phải lỗi của app. Apple Home cần Apple TV/HomePod để điều khiển khi ở ngoài.',
      ),
      const _Hint(
        icon: Icons.lock_outline_rounded,
        text:
            'Mã QR cho phép thêm người điều khiển ngôi nhà: không chụp màn hình hay gửi cho người khác. Có thể ngắt kết nối một ứng dụng bất cứ lúc nào ở danh sách trên.',
      ),
      const _Hint(
        icon: Icons.devices_other_rounded,
        text:
            'Các thiết bị sẽ xuất hiện trong Home app: công tắc dưới dạng đèn (mỗi gang một đèn), cảm biến cửa và cảm biến hiện diện. Thiết bị ghép mới vào Zigbee2MQTT cần khởi động lại dịch vụ Matter trên Pi mới hiện ra.',
      ),
    ];
  }
}

class _StatusCard extends StatelessWidget {
  final MatterInfo info;
  const _StatusCard({required this.info});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final n = info.fabrics.length;
    final title = !info.online
        ? 'Bridge đang khởi động'
        : n == 0
        ? 'Chưa ghép với ứng dụng nào'
        : 'Đã kết nối với $n ứng dụng';
    final sub = n == 0 ? 'Quét mã bên dưới trong Google Home hoặc Apple Home.' : 'Bạn có thể thêm ứng dụng khác hoặc ngắt kết nối.';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary, Color.lerp(cs.primary, const Color(0xFF0B5FA5), .55)!],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .2), borderRadius: BorderRadius.circular(16)),
            child: Icon(n == 0 ? Icons.hub_outlined : Icons.hub_rounded, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: tt.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                ),
                Text(sub, style: tt.bodySmall?.copyWith(color: Colors.white.withValues(alpha: .88))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QrCard extends StatelessWidget {
  final MatterInfo info;
  final VoidCallback? onClose;
  const _QrCard({required this.info, this.onClose});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final code = info.manualCodeFormatted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            // Nền trắng cố định kể cả chế độ tối để camera quét được.
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
              child: QrImageView(data: info.qr!, size: 230, backgroundColor: Colors.white, errorCorrectionLevel: QrErrorCorrectLevel.M),
            ),
            if (code != null) ...[
              const SizedBox(height: 16),
              Text('Hoặc nhập mã số', style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SelectableText(
                    code,
                    style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.5, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  IconButton(
                    tooltip: 'Sao chép',
                    icon: const Icon(Icons.copy_rounded, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: info.manualCode!));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã sao chép mã số')));
                    },
                  ),
                ],
              ),
            ],
            if (onClose != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(onPressed: onClose, icon: const Icon(Icons.close_rounded, size: 18), label: const Text('Đóng chế độ ghép nối')),
            ],
          ],
        ),
      ),
    );
  }
}

class _Guide extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<String> steps;
  const _Guide({required this.icon, required this.title, required this.steps});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icon, color: cs.primary),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(steps[i])),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Hint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String title, message;
  final Widget? action;
  const _Notice({required this.icon, required this.title, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 12),
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
