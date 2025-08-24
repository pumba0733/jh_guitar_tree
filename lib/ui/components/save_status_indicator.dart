// lib/ui/components/save_status_indicator.dart
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
        icon = Icons.autorenew;
        text = '저장 중…';
        break;
      case SaveState.saved:
        icon = Icons.check_circle;
        text = '저장됨';
        break;
      case SaveState.error:
        icon = Icons.error_outline;
        text = '오류';
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
        if (state == SaveState.saved && savedAt != null) ...[
          const SizedBox(width: 6),
          Text(
            '(${TimeOfDay.fromDateTime(savedAt!).format(context)})',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ]
      ],
    );
  }
}
