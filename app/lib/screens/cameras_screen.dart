import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';
import '../widgets/ui.dart';
import 'camera_live_screen.dart';

void openCamera(BuildContext context, Camera c) => Navigator.push(context, MaterialPageRoute(builder: (_) => CameraLiveScreen(camera: c)));

String cameraError(Object e) {
  final t = e.toString();
  if (t.contains('camera_unauthorized')) return 'Sai tài khoản hoặc mật khẩu camera';
  if (t.contains('camera_unreachable')) return 'Không kết nối được camera: kiểm tra địa chỉ, cổng ONVIF và camera có cùng mạng với addon không';
  if (t.contains('camera_onvif_error')) return 'Camera chưa bật ONVIF hoặc không hỗ trợ — bật ONVIF trong app của hãng, hoặc nhập URL RTSP';
  if (t.contains('addon offline') || t.contains('did not respond')) return 'Addon camera đang offline';
  if (t.contains('stream_unavailable')) return 'Không lấy được hình từ camera';
  return t;
}

/// Danh sách camera của căn hộ. Quản trị viên thêm/sửa/xoá; thành viên xem trực tiếp, quay PTZ.
class CamerasScreen extends StatelessWidget {
  const CamerasScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<AppModel>();
    final admin = m.home?.isAdmin == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera'),
        actions: [
          if (admin) IconButton(icon: const Icon(Icons.add_rounded), tooltip: 'Thêm camera', onPressed: () => showAddCameraSheet(context)),
          const InfoTip(
            'Camera',
            'Camera Wi‑Fi chạy qua addon camera (go2rtc) đặt trong nhà. Xem trực tiếp đi thẳng từ điện thoại tới addon; mạng nào không nối thẳng được thì app chuyển sang ảnh chụp làm mới mỗi giây.\n\nCamera có ONVIF thì quay PTZ và báo chuyển động được. Mật khẩu camera chỉ lưu ở addon trong nhà, không lưu trên máy chủ.',
            size: 22,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: m.reloadCameras,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (m.cameras.isEmpty)
              EmptyState(
                icon: Icons.videocam_rounded,
                colors: Vivid.info,
                title: 'Chưa có camera',
                info: 'Cần chạy addon camera (go2rtc) trên một máy trong nhà, rồi bấm "Thêm camera".',
                action: admin
                    ? FilledButton.icon(icon: const Icon(Icons.add_rounded), label: const Text('Thêm camera'), onPressed: () => showAddCameraSheet(context))
                    : null,
              ),
            for (final c in m.cameras) ...[_CameraCard(camera: c, admin: admin), const SizedBox(height: 12)],
          ],
        ),
      ),
    );
  }
}

class _CameraCard extends StatelessWidget {
  final Camera camera;
  final bool admin;
  const _CameraCard({required this.camera, required this.admin});

  @override
  Widget build(BuildContext context) {
    final m = context.read<AppModel>();
    final room = m.rooms.where((r) => r.id == camera.roomId).firstOrNull;
    final tt = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openCamera(context, camera),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: CameraThumb(camera: camera),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(camera.name, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            Pill(
                              camera.online ? Icons.circle : Icons.circle_outlined,
                              camera.online ? 'Online' : 'Offline',
                              color: camera.online ? const Color(0xFF16A34A) : Theme.of(context).colorScheme.error,
                            ),
                            if (room != null) Pill(room.kind.icon, room.name),
                            if (camera.hasPtz) const Pill(Icons.control_camera_rounded, 'PTZ'),
                            if (camera.hasEvents && camera.motionAlerts) const Pill(Icons.notifications_active_rounded, 'Báo chuyển động'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (admin) IconButton(tooltip: 'Cài đặt camera', icon: const Icon(Icons.tune_rounded), onPressed: () => showCameraSettings(context, camera)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ảnh xem trước của camera (tải một lần mỗi khi mở; giữ ảnh cũ trong bộ nhớ để danh sách không nháy).
class CameraThumb extends StatefulWidget {
  final Camera camera;
  const CameraThumb({super.key, required this.camera});
  static final Map<String, Uint8List> _cache = {};
  @override
  State<CameraThumb> createState() => _CameraThumbState();
}

class _CameraThumbState extends State<CameraThumb> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!widget.camera.online) return;
    try {
      final b = await context.read<AppModel>().api.cameraSnapshot(widget.camera.id, width: 480);
      CameraThumb._cache[widget.camera.id] = b;
      if (mounted) setState(() => _failed = false);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = CameraThumb._cache[widget.camera.id];
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF0F172A)),
        if (img != null) Image.memory(img, fit: BoxFit.cover, gaplessPlayback: true),
        if (img == null)
          Center(
            child: widget.camera.online && !_failed
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white54))
                : const Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 36),
          ),
        const Align(
          alignment: Alignment.center,
          child: CircleAvatar(
            radius: 22,
            backgroundColor: Colors.black45,
            child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── thêm camera ─────────────────────────

Future<void> showAddCameraSheet(BuildContext context) => showCenterSheet<void>(context: context, builder: (_) => const _AddCameraSheet());

class _AddCameraSheet extends StatefulWidget {
  const _AddCameraSheet();
  @override
  State<_AddCameraSheet> createState() => _AddCameraSheetState();
}

class _AddCameraSheetState extends State<_AddCameraSheet> {
  late final AppModel _m = context.read<AppModel>();
  final _name = TextEditingController(text: 'Camera');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '80');
  final _user = TextEditingController(text: 'admin');
  final _pass = TextEditingController();
  final _rtsp = TextEditingController();
  bool _useRtsp = false;
  bool _scanning = false;
  bool _saving = false;
  bool _showPass = false;
  List<FoundCamera>? _found;
  String? _gatewayId;
  String? _roomId;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _user, _pass, _rtsp]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      _found = await _m.api.scanCameras(_m.home!.id);
    } catch (e) {
      _error = cameraError(e);
    }
    if (mounted) setState(() => _scanning = false);
  }

  void _pick(FoundCamera f) {
    setState(() {
      _useRtsp = false;
      _host.text = f.host;
      _port.text = '${f.port}';
      _gatewayId = f.gatewayId;
      if (f.name != null && (_name.text.isEmpty || _name.text == 'Camera')) _name.text = f.name!;
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Đặt tên cho camera');
    if (_useRtsp && !_rtsp.text.trim().startsWith('rtsp')) return setState(() => _error = 'URL phải bắt đầu bằng rtsp://');
    if (!_useRtsp && _host.text.trim().isEmpty) return setState(() => _error = 'Nhập địa chỉ IP của camera');
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _m.api.addCamera(_m.home!.id, {
        'name': name,
        'room_id': ?_roomId,
        'gateway_id': ?_gatewayId,
        'username': _user.text.trim(),
        'password': _pass.text,
        if (_useRtsp) 'rtsp_url': _rtsp.text.trim() else ...{'host': _host.text.trim(), 'port': int.tryParse(_port.text.trim()) ?? 80},
      });
      await _m.reloadCameras();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = cameraError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            children: [
              Row(
                children: [
                  const IconBadge(Icons.videocam_rounded, colors: Vivid.info, size: 44),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Thêm camera', style: tt.titleLarge)),
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _scanning ? null : _scan,
                icon: _scanning ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.radar_rounded),
                label: Text(_scanning ? 'Đang tìm camera ONVIF…' : 'Tìm camera trong mạng'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              if (_found != null) ...[
                const SizedBox(height: 8),
                if (_found!.isEmpty)
                  Text(
                    'Không thấy camera ONVIF nào. Bật ONVIF trong app của hãng, hoặc nhập tay bên dưới.',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                for (final f in _found!)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const IconBadge(Icons.videocam_outlined, colors: Vivid.info, size: 32),
                    title: Text(f.name ?? f.host, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${f.host}:${f.port}${f.hardware != null ? ' · ${f.hardware}' : ''}'),
                    trailing: f.added ? const Text('Đã thêm') : (_host.text == f.host ? Icon(Icons.check_circle_rounded, color: cs.primary) : null),
                    enabled: !f.added,
                    onTap: () => _pick(f),
                  ),
              ],
              const SizedBox(height: 14),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('ONVIF'), icon: Icon(Icons.hub_rounded)),
                  ButtonSegment(value: true, label: Text('URL RTSP'), icon: Icon(Icons.link_rounded)),
                ],
                selected: {_useRtsp},
                onSelectionChanged: (s) => setState(() => _useRtsp = s.first),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _name,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Tên camera', counterText: ''),
              ),
              const SizedBox(height: 10),
              if (_useRtsp)
                TextField(
                  controller: _rtsp,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'URL RTSP', hintText: 'rtsp://192.168.1.20:554/stream1'),
                )
              else
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(labelText: 'Địa chỉ IP', hintText: '192.168.1.20'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Cổng'),
                      ),
                    ),
                  ],
                ),
              if (!_useRtsp)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text('Cổng ONVIF: thường 80; Tapo 2020; một số hãng 8000 hoặc 8899.', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: _user,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Tài khoản camera'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _pass,
                obscureText: !_showPass,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Mật khẩu camera',
                  helperText: 'Chỉ lưu ở addon trong nhà, không lưu trên máy chủ',
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(_showPass ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                    onPressed: () => setState(() => _showPass = !_showPass),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('Phòng', style: tt.titleSmall),
              const SizedBox(height: 8),
              _RoomChips(selected: _roomId, onSelect: (r) => setState(() => _roomId = r)),
              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
                  child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
                ),
            ],
          ),
        ),
        _Buttons(saving: _saving, onSave: _save, saveLabel: 'Thêm'),
      ],
    );
  }
}

class _RoomChips extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onSelect;
  const _RoomChips({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final rooms = context.read<AppModel>().rooms;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(showCheckmark: false, label: const Text('Không chọn'), selected: selected == null, onSelected: (_) => onSelect(null)),
        for (final r in rooms)
          ChoiceChip(
            showCheckmark: false,
            avatar: Icon(r.kind.icon, size: 18),
            label: Text(r.name),
            selected: selected == r.id,
            onSelected: (_) => onSelect(r.id),
          ),
      ],
    );
  }
}

class _Buttons extends StatelessWidget {
  final bool saving;
  final VoidCallback onSave;
  final String saveLabel;
  final Widget? leading;
  const _Buttons({required this.saving, required this.onSave, required this.saveLabel, this.leading});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Row(
          children: [
            ?leading,
            Expanded(
              child: OutlinedButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Huỷ'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: saving ? null : onSave,
                child: saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)) : Text(saveLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── cài đặt camera ─────────────────────────

Future<void> showCameraSettings(BuildContext context, Camera c) => showCenterSheet<void>(
  context: context,
  builder: (_) => _CameraSettings(camera: c),
);

class _CameraSettings extends StatefulWidget {
  final Camera camera;
  const _CameraSettings({required this.camera});
  @override
  State<_CameraSettings> createState() => _CameraSettingsState();
}

class _CameraSettingsState extends State<_CameraSettings> {
  late final AppModel _m = context.read<AppModel>();
  late final _name = TextEditingController(text: widget.camera.name);
  late String? _roomId = widget.camera.roomId;
  late bool _alerts = widget.camera.motionAlerts;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Tên không được để trống');
    setState(() => _saving = true);
    try {
      await _m.api.updateCamera(widget.camera.id, {'name': name, 'room_id': _roomId, 'clear_room': _roomId == null, 'motion_alerts': _alerts});
      await _m.reloadCameras();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = cameraError(e);
        });
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Xoá camera?'),
        content: Text('Bỏ "${widget.camera.name}" khỏi căn hộ. Addon cũng xoá mật khẩu camera đã lưu.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _m.api.deleteCamera(widget.camera.id);
      await _m.reloadCameras();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = cameraError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.camera;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            children: [
              Row(
                children: [
                  const IconBadge(Icons.videocam_rounded, colors: Vivid.info, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Cài đặt camera', style: tt.titleLarge),
                        Text([c.subtitle, c.host].where((s) => s.isNotEmpty).join(' · '), style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _name,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Tên camera', counterText: ''),
              ),
              const SizedBox(height: 16),
              Text('Phòng', style: tt.titleSmall),
              const SizedBox(height: 8),
              _RoomChips(selected: _roomId, onSelect: (r) => setState(() => _roomId = r)),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _alerts && c.hasEvents,
                onChanged: c.hasEvents ? (v) => setState(() => _alerts = v) : null,
                title: const Text('Cảnh báo chuyển động'),
                subtitle: Text(c.hasEvents ? 'Báo tối đa 1 lần/phút khi camera phát hiện chuyển động' : 'Camera không báo sự kiện qua ONVIF'),
              ),
              if (_error != null) Text(_error!, style: TextStyle(color: cs.error)),
            ],
          ),
        ),
        _Buttons(
          saving: _saving,
          onSave: _save,
          saveLabel: 'Lưu',
          leading: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: 'Xoá camera',
              icon: Icon(Icons.delete_outline_rounded, color: cs.error),
              onPressed: _saving ? null : _delete,
            ),
          ),
        ),
      ],
    );
  }
}
