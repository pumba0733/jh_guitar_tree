// lib/ui/components/save_status_indicator.dart
// v1.21.2 | 재시도 큐 대기수 표시 옵션 추가
import 'package:flutter/material.dart';

enum SaveStatus { idle, saving, saved, failed }

class SaveStatusIndicator extends StatelessWidget {
  final SaveStatus status;
  final DateTime? lastSavedAt;
  final int pendingRetryCount;

  const SaveStatusIndicator({
    super.key,
    required this.status,
    this.lastSavedAt,
    this.pendingRetryCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;
    String text;

    switch (status) {
      case SaveStatus.idle:
        icon = Icons.check_circle_outline;
        color = Colors.grey;
        text = '대기 중';
        break;
      case SaveStatus.saving:
        icon = Icons.sync;
        color = Colors.blue;
        text = '저장 중…';
        break;
      case SaveStatus.saved:
        icon = Icons.check_circle;
        color = Colors.green;
        final time = lastSavedAt != null ? ' (${_fmtTime(lastSavedAt!)})' : '';
        final tail = pendingRetryCount > 0 ? ' · 재시도 $pendingRetryCount' : '';
        text = '저장됨$time$tail';
        break;
      case SaveStatus.failed:
        icon = Icons.error_outline;
        color = Colors.red;
        final tail = pendingRetryCount > 0 ? ' · 대기 $pendingRetryCount' : '';
        text = '실패$tail';
        break;
    }

    final style = TextStyle(fontSize: 12, color: color);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(text, style: style),
      ],
    );
  }

  String _fmtTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
