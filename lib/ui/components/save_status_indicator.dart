import 'package:flutter/material.dart';

enum SaveStatus { saved, saving, failed }

class SaveStatusIndicator extends StatelessWidget {
  final SaveStatus status;
  final DateTime? lastSavedTime;

  const SaveStatusIndicator({
    super.key,
    required this.status,
    this.lastSavedTime,
  });

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case SaveStatus.saved:
        return Text(
          '✅ 저장됨 (${_formatTime(lastSavedTime)})',
          style: const TextStyle(color: Colors.green),
        );
      case SaveStatus.saving:
        return const Text('⏳ 저장 중...', style: TextStyle(color: Colors.orange));
      case SaveStatus.failed:
        return const Text('⚠️ 저장 실패', style: TextStyle(color: Colors.red));
    }
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    return '${time.hour}:${time.minute.toString().padLeft(2, '0')}';
  }
}
