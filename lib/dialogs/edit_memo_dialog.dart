import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/services/student_service.dart';

class EditMemoDialog extends StatefulWidget {
  final String studentId;
  final String initialMemo;

  const EditMemoDialog({
    super.key,
    required this.studentId,
    required this.initialMemo,
  });

  @override
  State<EditMemoDialog> createState() => _EditMemoDialogState();
}

class _EditMemoDialogState extends State<EditMemoDialog> {
  late TextEditingController memoController;
  final StudentService _studentService = StudentService();

  @override
  void initState() {
    super.initState();
    memoController = TextEditingController(text: widget.initialMemo);
  }

  void saveMemo() async {
    final newMemo = memoController.text.trim();
    await _studentService.updateMemo(widget.studentId, newMemo);
    if (!mounted) return;
    Navigator.of(context).pop(newMemo); // 안전하게 context 사용
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('메모 수정'),
      content: TextField(
        controller: memoController,
        maxLines: 8,
        decoration: const InputDecoration(
          hintText: '메모를 입력하세요...',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        ElevatedButton(onPressed: saveMemo, child: const Text('저장')),
      ],
    );
  }
}
