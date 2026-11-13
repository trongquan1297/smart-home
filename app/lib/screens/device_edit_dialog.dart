import 'package:flutter/material.dart';

import '../app_model.dart';
import '../models.dart';

/// Sửa thiết bị: đổi tên, chọn phòng, đặt tên + loại tải cho từng gang (đèn, quạt, ổ cắm...).
Future<void> showDeviceEditDialog(BuildContext context, AppModel m, Device d) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _DeviceEditSheet(model: m, device: d),
  );
}

class _DeviceEditSheet extends StatefulWidget {
  final AppModel model;
  final Device device;
  const _DeviceEditSheet({required this.model, required this.device});
  @override
  State<_DeviceEditSheet> createState() => _DeviceEditSheetState();
}

class _DeviceEditSheetState extends State<_DeviceEditSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.device.name);
  late String? _roomId = widget.device.roomId;
  late final Map<String, TextEditingController> _chName = {
    for (final k in widget.device.switchKeys) k: TextEditingController(text: widget.device.channels[k]?.name ?? ''),
  };
  late final Map<String, ChannelType> _chType = {
    for (final k in widget.device.switchKeys) k: widget.device.channelType(k),
  };
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    for (final c in _chName.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Tên thiết bị không được để trống');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.model.api.updateDevice(
        widget.device.id,
        name: name,
        roomId: _roomId,
        clearRoom: _roomId == null,
        channels: {
          for (final k in widget.device.switchKeys) k: Channel(name: _chName[k]!.text.trim(), type: _chType[k]!),
        },
      );
      await widget.model.reload();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final multi = d.switchKeys.length > 1;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .92,
      maxChildSize: .95,
      minChildSize: .5,
      builder: (_, scroll) => Column(children: [
        Expanded(
          child: ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), children: [
            Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(16)),
                child: Icon(d.isSensor ? Icons.sensors_rounded : Icons.toggle_on_rounded, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Sửa thiết bị', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  Text('${d.typeLabel}${d.model != null ? ' · ${d.model}' : ''}', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ]),
              ),
            ]),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              maxLength: 100,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Tên thiết bị', prefixIcon: Icon(Icons.label_outline_rounded), counterText: ''),
            ),
            const SizedBox(height: 18),
            Text('Phòng', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(
                showCheckmark: false,
                avatar: const Icon(Icons.help_outline_rounded, size: 18),
                label: const Text('Chưa phân phòng'),
                selected: _roomId == null,
                onSelected: (_) => setState(() => _roomId = null),
              ),
              for (final r in widget.model.rooms)
                ChoiceChip(
                  showCheckmark: false,
                  avatar: Icon(r.kind.icon, size: 18),
                  label: Text(r.name),
                  selected: _roomId == r.id,
                  onSelected: (_) => setState(() => _roomId = r.id),
                ),
            ]),
            if (d.switchKeys.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text(multi ? 'Các gang' : 'Tải điều khiển', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text('Đặt tên và chọn loại để dễ nhận biết (đèn, quạt, ổ cắm...).', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 10),
              for (final k in d.switchKeys)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: .4),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(_chType[k]!.icon, size: 20, color: cs.primary),
                      const SizedBox(width: 8),
                      Text(d.defaultLabel(k), style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _chName[k],
                      maxLength: 60,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(hintText: 'vd: Đèn trần', counterText: ''),
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final t in ChannelType.values)
                        ChoiceChip(
                          showCheckmark: false,
                          avatar: Icon(t.icon, size: 16),
                          label: Text(t.label),
                          visualDensity: VisualDensity.compact,
                          selected: _chType[k] == t,
                          onSelected: (_) => setState(() => _chType[k] = t),
                        ),
                    ]),
                  ]),
                ),
            ],
            if (_error != null)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
                child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
              ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 12 + MediaQuery.of(context).viewInsets.bottom),
            child: Row(children: [
              Expanded(child: OutlinedButton(onPressed: _saving ? null : () => Navigator.pop(context), style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), child: const Text('Huỷ'))),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Text('Lưu'),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
