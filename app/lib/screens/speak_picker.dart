import 'package:flutter/material.dart';

import '../app_model.dart';
import '../widgets/ui.dart';

/// Chọn loa Cast và câu đọc cho một hành động tự động (ngữ cảnh hoặc luật ⚡). Trống loa = không đọc; trống câu = câu tự sinh.
class SpeakPicker extends StatelessWidget {
  final AppModel model;
  final Set<String> selected;
  final TextEditingController text;
  final String hint; // ví dụ câu tự sinh
  final VoidCallback onChanged;
  const SpeakPicker({super.key, required this.model, required this.selected, required this.text, required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final speakers = model.speakers;
    if (speakers.isEmpty) {
      return const Row(children: [Pill(Icons.speaker_rounded, 'Chưa có loa'), InfoTip('Thêm loa', 'Thêm loa ở menu ⋮ → Loa thông báo trên màn hình căn hộ.')]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final s in speakers)
              FilterChip(
                avatar: const Icon(Icons.speaker_rounded, size: 18),
                label: Text(s.name),
                selected: selected.contains(s.id),
                onSelected: (v) {
                  v ? selected.add(s.id) : selected.remove(s.id);
                  onChanged();
                },
              ),
          ],
        ),
        if (selected.isNotEmpty) ...[
          const SizedBox(height: 8),
          TextField(
            controller: text,
            maxLength: 140,
            decoration: InputDecoration(labelText: 'Câu đọc (để trống = tự sinh)', hintText: hint, border: const OutlineInputBorder()),
          ),
        ],
      ],
    );
  }
}

/// Hộp thoại chọn loa + câu cho một luật ⚡. Trả về (loa, câu) hoặc null nếu huỷ.
Future<({List<String> ids, String text})?> showSpeakDialog(
  BuildContext context,
  AppModel m, {
  required List<String> ids,
  required String? text,
  required String hint,
}) {
  final sel = {...ids};
  final ctrl = TextEditingController(text: text ?? '');
  return showDialog<({List<String> ids, String text})>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Thông báo qua loa'),
        content: SingleChildScrollView(
          child: SpeakPicker(model: m, selected: sel, text: ctrl, hint: hint, onChanged: () => set(() {})),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, (ids: sel.toList(), text: ctrl.text.trim())), child: const Text('Lưu')),
        ],
      ),
    ),
  );
}
