import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../app_model.dart';
import '../models.dart';

enum _Mode { connecting, live, snapshot, error }

/// Chỉ để thử chế độ dự phòng (flutter run --dart-define=CAMERA_FORCE_SNAPSHOT=true): bỏ qua WebRTC.
const _forceSnapshot = bool.fromEnvironment('CAMERA_FORCE_SNAPSHOT');

/// Xem trực tiếp một camera. Ưu tiên WebRTC (điện thoại nối thẳng tới go2rtc trong nhà, máy chủ chỉ chuyển SDP);
/// không nối được trong vài giây (NAT đối xứng, 4G…) thì chuyển sang ảnh chụp làm mới ~1 giây/lần qua máy chủ.
class CameraLiveScreen extends StatefulWidget {
  final Camera camera;
  const CameraLiveScreen({super.key, required this.camera});
  @override
  State<CameraLiveScreen> createState() => _CameraLiveScreenState();
}

class _CameraLiveScreenState extends State<CameraLiveScreen> {
  late final AppModel _m = context.read<AppModel>();
  final _renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  _Mode _mode = _Mode.connecting;
  Uint8List? _snap;
  Timer? _fallback;
  bool _polling = false;
  bool _disposed = false;
  String? _error;

  Camera get cam => widget.camera;

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) => _startLive());
  }

  @override
  void dispose() {
    _disposed = true;
    _fallback?.cancel();
    _closePc();
    _renderer.dispose();
    if (cam.hasPtz) _m.api.cameraPtz(cam.id).catchError((_) {}); // không để camera quay tiếp khi rời màn hình
    super.dispose();
  }

  void _closePc() {
    final pc = _pc;
    _pc = null;
    _renderer.srcObject = null;
    pc?.close();
  }

  void _set(_Mode m, {String? error}) {
    if (_disposed) return;
    setState(() {
      _mode = m;
      _error = error;
    });
  }

  Future<void> _startLive() async {
    _polling = false;
    _set(_Mode.connecting);
    if (_forceSnapshot) return _toSnapshot();
    try {
      final pc = await createPeerConnection({
        // STUN công khai chỉ để điện thoại biết địa chỉ công khai của mình (không đi qua hình ảnh).
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        'sdpSemantics': 'unified-plan',
      });
      _pc = pc;
      for (final kind in [RTCRtpMediaType.RTCRtpMediaTypeVideo, RTCRtpMediaType.RTCRtpMediaTypeAudio]) {
        await pc.addTransceiver(
          kind: kind,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      pc.onTrack = (e) {
        if (e.track.kind == 'video' && e.streams.isNotEmpty) _renderer.srcObject = e.streams.first;
      };
      pc.onConnectionState = (s) {
        if (_pc != pc) return;
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _fallback?.cancel();
          _set(_Mode.live);
        } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed || s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _toSnapshot();
        }
      };
      // go2rtc nhận một offer đầy đủ (không trickle ICE): chờ gom candidate xong, tối đa 3 giây.
      final gathered = Completer<void>();
      pc.onIceGatheringState = (s) {
        if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !gathered.isCompleted) gathered.complete();
      };
      await pc.setLocalDescription(await pc.createOffer());
      await gathered.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      final local = await pc.getLocalDescription();
      if (_pc != pc || local?.sdp == null) return;
      final answer = await _m.api.cameraWebrtc(cam.id, local!.sdp!);
      if (_pc != pc) return;
      await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
      _fallback?.cancel();
      _fallback = Timer(const Duration(seconds: 8), () {
        if (_mode != _Mode.live) _toSnapshot();
      });
    } catch (e) {
      _toSnapshot(error: e.toString());
    }
  }

  /// Dự phòng: ảnh tĩnh làm mới liên tục (mỗi ảnh xong mới tải ảnh sau, nghỉ 1 giây).
  Future<void> _toSnapshot({String? error}) async {
    _fallback?.cancel();
    _closePc();
    if (_polling || _disposed) return;
    _polling = true;
    _set(_Mode.snapshot);
    var failures = 0;
    while (_polling && !_disposed) {
      try {
        final b = await _m.api.cameraSnapshot(cam.id, width: 960);
        if (!_polling || _disposed) break;
        failures = 0;
        setState(() {
          _snap = b;
          _mode = _Mode.snapshot;
          _error = null;
        });
      } catch (e) {
        if (++failures >= 3) {
          _polling = false;
          _set(_Mode.error, error: _friendly(e.toString()));
          break;
        }
      }
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  String _friendly(String e) {
    if (e.contains('addon offline') || e.contains('did not respond')) return 'Addon camera đang offline';
    if (e.contains('stream_unavailable')) return 'Không lấy được hình từ camera';
    return e;
  }

  Future<void> _ptz({double pan = 0, double tilt = 0, double zoom = 0}) async {
    try {
      await _m.api.cameraPtz(cam.id, pan: pan, tilt: tilt, zoom: zoom);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(e.toString()))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = context.select<AppModel, Camera?>((m) => m.cameras.where((c) => c.id == cam.id).firstOrNull) ?? cam;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: Text(live.name, style: const TextStyle(color: Colors.white)),
        actions: [
          if (_mode == _Mode.snapshot || _mode == _Mode.error)
            IconButton(tooltip: 'Thử xem trực tiếp lại', icon: const Icon(Icons.refresh_rounded), onPressed: _startLive),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  InteractiveViewer(maxScale: 4, child: _view()),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _StatusChip(mode: _mode, online: live.online),
                  ),
                ],
              ),
            ),
            if (_error != null && _mode == _Mode.error)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            const Spacer(),
            if (live.hasPtz) _PtzPad(onMove: _ptz),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _view() {
    if (_mode == _Mode.live || (_mode == _Mode.connecting && _renderer.srcObject != null)) {
      return RTCVideoView(_renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);
    }
    if (_snap != null) return Image.memory(_snap!, gaplessPlayback: true, fit: BoxFit.contain);
    if (_mode == _Mode.error) return const Center(child: Icon(Icons.videocam_off_rounded, color: Colors.white38, size: 56));
    return const Center(child: CircularProgressIndicator(color: Colors.white70));
  }
}

class _StatusChip extends StatelessWidget {
  final _Mode mode;
  final bool online;
  const _StatusChip({required this.mode, required this.online});

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (mode) {
      _Mode.live => (const Color(0xFF22C55E), 'Trực tiếp'),
      _Mode.snapshot => (const Color(0xFFF59E0B), 'Ảnh 1 giây/lần'),
      _Mode.connecting => (Colors.white70, 'Đang kết nối…'),
      _Mode.error => (const Color(0xFFEF4444), online ? 'Lỗi' : 'Camera offline'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(99)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Bàn phím PTZ: giữ nút để quay, thả ra để dừng. Zoom +/- cũng giữ để zoom.
class _PtzPad extends StatelessWidget {
  final Future<void> Function({double pan, double tilt, double zoom}) onMove;
  const _PtzPad({required this.onMove});

  static const _speed = 0.5;

  Widget _hold(IconData icon, String tip, {double pan = 0, double tilt = 0, double zoom = 0, double size = 56}) {
    return Tooltip(
      message: tip,
      child: Listener(
        onPointerDown: (_) {
          HapticFeedback.selectionClick();
          onMove(pan: pan, tilt: tilt, zoom: zoom);
        },
        onPointerUp: (_) => onMove(),
        onPointerCancel: (_) => onMove(),
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: Color(0x26FFFFFF), shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: size * .5),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 184,
          height: 184,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: const BoxDecoration(color: Color(0x14FFFFFF), shape: BoxShape.circle),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: _hold(Icons.keyboard_arrow_up_rounded, 'Ngẩng lên', tilt: _speed),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: _hold(Icons.keyboard_arrow_down_rounded, 'Cúi xuống', tilt: -_speed),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: _hold(Icons.keyboard_arrow_left_rounded, 'Quay trái', pan: -_speed),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: _hold(Icons.keyboard_arrow_right_rounded, 'Quay phải', pan: _speed),
              ),
              const Icon(Icons.control_camera_rounded, color: Colors.white38, size: 28),
            ],
          ),
        ),
        const SizedBox(width: 28),
        Column(
          children: [
            _hold(Icons.zoom_in_rounded, 'Phóng to', zoom: _speed, size: 52),
            const SizedBox(height: 16),
            _hold(Icons.zoom_out_rounded, 'Thu nhỏ', zoom: -_speed, size: 52),
          ],
        ),
      ],
    );
  }
}
