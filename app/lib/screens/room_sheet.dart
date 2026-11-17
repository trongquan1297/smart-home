import 'package:flutter/material.dart';

import '../app_model.dart';
import '../models.dart';
import '../widgets/ui.dart';

/// Tạo phòng mới (room == null) hoặc sửa/xoá phòng: tên + icon. Icon tự gợi ý theo tên cho tới khi người dùng chọn tay.
Future<void> showRoomSheet(BuildContext context, AppModel m, {Room? room}) {
  return showCenterSheet<void>(
    context: context,
    builder: (_) => _RoomSheet(model: m, room: room),
  );
}

class _RoomSheet extends StatefulWidget {
  final AppModel model;
  final Room? room;
  const _RoomSheet({required this.model, this.room});
  @override
  State<_RoomSheet> createState() => _RoomSheetState();
}

class _RoomSheetState extends State<_RoomSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.room?.name ?? '');
  late RoomKind _kind = widget.room?.kind ?? RoomKind.living;
  late bool _picked = widget.room?.icon != null; // đã chọn tay → không tự đổi theo tên nữa
  bool _busy = false;
  String? _error;

  bool get _editing => widget.room != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Nhập tên phòng');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = widget.model;
    try {
      if (_editing) {
        await m.api.updateRoom(widget.room!.id, name: name, icon: _kind.id);
      } else {
        await m.api.createRoom(m.home!.id, name, icon: _kind.id);
      }
      await m.reload();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Xoá phòng?'),
        content: Text('Xoá "${widget.room!.name}". Thiết bị trong phòng không bị xoá, chỉ chuyển về "Chưa phân phòng".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.model.api.deleteRoom(widget.room!.id);
      await widget.model.reload();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: IconBadge(_kind.icon, key: ValueKey(_kind), colors: roomColors(_kind.id), size: 48),
                ),
                const SizedBox(width: 14),
                Text(_editing ? 'Sửa phòng' : 'Phòng mới', style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _name,
              autofocus: !_editing,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 100,
              decoration: const InputDecoration(labelText: 'Tên phòng', hintText: 'vd: Phòng khách', counterText: ''),
              onChanged: (v) {
                if (!_picked) setState(() => _kind = RoomKind.guess(v));
              },
            ),
            const SizedBox(height: 16),
            Text('Biểu tượng', style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (_, c) {
                const gap = 8.0;
                final w = (c.maxWidth - gap * 3) / 4; // 4 ô mỗi hàng, vừa khít chiều rộng
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final k in RoomKind.values)
                      _KindTile(
                        kind: k,
                        width: w,
                        selected: k == _kind,
                        onTap: () => setState(() {
                          _kind = k;
                          _picked = true;
                        }),
                      ),
                  ],
                );
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: cs.error)),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (_editing)
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: cs.error),
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Xoá'),
                  ),
                const Spacer(),
                TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Huỷ')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _busy ? null : _save, child: Text(_editing ? 'Lưu' : 'Tạo phòng')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _KindTile extends StatelessWidget {
  final RoomKind kind;
  final double width;
  final bool selected;
  final VoidCallback onTap;
  const _KindTile({required this.kind, required this.width, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: width,
      decoration: BoxDecoration(
        color: selected ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: selected ? cs.primary : Colors.transparent, width: 1.6),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
          child: Column(
            children: [
              Icon(kind.icon, color: selected ? cs.onPrimaryContainer : roomColors(kind.id).first),
              const SizedBox(height: 4),
              Text(
                kind.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
