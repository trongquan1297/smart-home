import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';
import '../widgets/ui.dart';

/// Loa Google Cast (Google Home / Nest Mini…) dùng để đọc thông báo bằng tiếng Việt khi ngữ cảnh hoặc luật ⚡ tự chạy.
/// Bộ điều khiển trung tâm tìm loa qua mạng LAN (mDNS) nên phải đang online và cùng mạng với loa.
class SpeakersScreen extends StatefulWidget {
  const SpeakersScreen({super.key});
  @override
  State<SpeakersScreen> createState() => _SpeakersScreenState();
}

class _SpeakersScreenState extends State<SpeakersScreen> {
  String? _busy; // id loa đang thử
  bool _scanning = false;

  AppModel get m => context.read<AppModel>();

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  String _err(Object e) {
    final t = e.toString();
    if (t.contains('no speaker-capable gateway')) {
      return 'Chưa có gateway nào hỗ trợ loa đang online. Gateway phải chạy ở máy cùng mạng LAN với loa (bản mới, xem README) — máy chủ trên đám mây không thấy được loa trong nhà.';
    }
    if (t.contains('did not respond')) return 'Gateway không phản hồi. Gateway cũ chưa hỗ trợ loa: hãy build lại bản mới.';
    if (t.contains('cast discovery unavailable')) return 'Gateway không quét được mạng LAN (mDNS). Gateway cần chạy với network_mode: host.';
    if (t.contains('gateway offline')) return 'Bộ điều khiển trung tâm đang offline';
    return t;
  }

  Future<void> _test(Speaker s) async {
    setState(() => _busy = s.id);
    try {
      await m.api.testSpeaker(s.id);
      _snack('Đã gửi câu thử tới "${s.name}"');
    } catch (e) {
      _snack(_err(e));
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _delete(Speaker s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Xoá loa?'),
        content: Text('Bỏ "${s.name}" khỏi căn hộ và khỏi các ngữ cảnh/luật đang dùng loa này.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await m.api.deleteSpeaker(s.id);
      await m.reloadSpeakers();
      await m.reloadScenes();
      await m.reloadRules();
    } catch (e) {
      _snack(_err(e));
    }
  }

  Future<void> _add() async {
    setState(() => _scanning = true);
    List<FoundSpeaker> found = [];
    String? error;
    try {
      found = await m.api.scanSpeakers(m.home!.id);
    } catch (e) {
      error = _err(e);
    }
    if (!mounted) return;
    setState(() => _scanning = false);
    if (error != null) return _snack(error);
    final fresh = found.where((f) => !f.added).toList();
    if (fresh.isEmpty) {
      return _snack(found.isEmpty ? 'Không tìm thấy loa Cast nào trong mạng LAN của bộ điều khiển trung tâm' : 'Mọi loa tìm thấy đã được thêm');
    }
    final pick = await showCenterSheet<FoundSpeaker>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Chọn loa để thêm', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final f in fresh)
              ListTile(
                leading: const Icon(Icons.speaker_rounded),
                title: Text(f.name),
                subtitle: Text('${f.model.isEmpty ? 'Google Cast' : f.model} · ${f.host}'),
                onTap: () => Navigator.pop(c, f),
              ),
          ],
        ),
      ),
    );
    if (pick == null || !mounted) return;
    final ctrl = TextEditingController(text: pick.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Tên loa'),
        content: TextField(controller: ctrl, autofocus: true, maxLength: 60),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Thêm')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await m.api.addSpeaker(m.home!.id, pick, name);
      await m.reloadSpeakers();
    } catch (e) {
      _snack(_err(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loa thông báo'),
        actions: [
          IconButton(
            tooltip: 'Thêm loa',
            onPressed: _scanning ? null : _add,
            icon: _scanning ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add_rounded),
          ),
          const InfoTip(
            'Loa thông báo',
            'Loa Google Home / Nest Mini đọc thông báo bằng tiếng Việt khi ngữ cảnh hoặc luật ⚡ tự chạy. Loa phải cùng mạng Wi‑Fi/LAN với một bộ điều khiển trung tâm hỗ trợ loa.\n\nGiọng đọc dùng Google Translate TTS (không chính thức, có thể bị đổi hoặc chặn). Khi đọc, loa tạm dừng nhạc đang phát.',
            size: 22,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (model.speakers.isEmpty)
            const EmptyState(
              icon: Icons.speaker_rounded,
              colors: Vivid.speak,
              title: 'Chưa có loa nào',
              info: 'Bấm "Thêm loa" để tìm Google Home / Nest Mini trong mạng LAN của bộ điều khiển trung tâm.',
            ),
          for (final s in model.speakers)
            Card(
              child: ListTile(
                leading: const IconBadge(Icons.speaker_rounded, colors: Vivid.speak, size: 42),
                title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(s.host ?? s.castId),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _busy == s.id
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(icon: const Icon(Icons.play_arrow_rounded), tooltip: 'Phát thử', onPressed: () => _test(s)),
                    IconButton(icon: const Icon(Icons.delete_outline_rounded), tooltip: 'Xoá', onPressed: () => _delete(s)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
