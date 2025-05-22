// 📄 lib/dialogs/confirm_delete_dialog.dart

import 'package:flutter/material.dart';

class ConfirmDeleteDialog extends StatelessWidget {
  final String name;

  const ConfirmDeleteDialog({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('학생 삭제 확인'),
      content: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style,
          children: [
            const TextSpan(text: '정말로 '),
            TextSpan(
              text: name,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
            const TextSpan(text: ' 학생을 삭제하시겠어요?\n\n'),
            const TextSpan(
              text: '❗ 삭제된 학생 정보는 복원할 수 없습니다.',
              style: TextStyle(color: Colors.red),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('삭제'),
        ),
      ],
    );
  }
}
