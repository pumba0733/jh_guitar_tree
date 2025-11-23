// lib/packages/smart_media_player/ui/smp_notes_panel.dart
import 'package:flutter/material.dart';

class SmpNotesPanel extends StatelessWidget {
  final TextEditingController controller;
  final void Function(String text) onChanged;

  const SmpNotesPanel({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('오늘 수업 메모'),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: 6,
          onChanged: onChanged,
          decoration: const InputDecoration(
            hintText: '오늘 배운 것/과제/포인트…',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}
