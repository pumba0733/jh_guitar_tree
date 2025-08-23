// lib/ui/components/save_status_indicator.dart
// v1.06 | 저장 상태 표시 위젯 (⏳/✅/⚠️)
import 'package:flutter/material.dart';

enum SaveState { idle, saving, saved, error }

class SaveStatusIndicator extends StatelessWidget {
  final SaveState state;
  final DateTime? savedAt;
  const SaveStatusIndicator({super.key, required this.state, this.savedAt});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    String text;
    switch (state) {
      case SaveState.saving:
        icon = Icons.sync;
        text = '저장 중…';
        break;
      case SaveState.saved:
        icon = Icons.check_circle;
        final t = savedAt != null
            ? '저장됨 (${TimeOfDay.fromDateTime(savedAt!).format(context)})'
            : '저장됨';
        text = t;
        break;
      case SaveState.error:
        icon = Icons.error_outline;
        text = '저장 실패';
        break;
      case SaveState.idle:
      default:
        icon = Icons.more_horiz;
        text = '대기';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
