// lib/screens/curriculum/curriculum_assign_dialog.dart
// v1.39.0 | 커리큘럼 배정 다이얼로그(간단 버전)
// - 다음 버전에서: 학생 검색/선택 UI, 배정 경로(path) 미리보기, 중복 방지 등 고도화

import 'package:flutter/material.dart';
import '../../services/curriculum_service.dart';

class CurriculumAssignDialog extends StatefulWidget {
  final String nodeId;
  final String nodeTitle;
  const CurriculumAssignDialog({
    super.key,
    required this.nodeId,
    required this.nodeTitle,
  });

  @override
  State<CurriculumAssignDialog> createState() => _CurriculumAssignDialogState();
}

class _CurriculumAssignDialogState extends State<CurriculumAssignDialog> {
  final _formKey = GlobalKey<FormState>();
  final _studentIdCtrl = TextEditingController();
  bool _busy = false;
  final _svc = CurriculumService();

  @override
  void dispose() {
    _studentIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await _svc.assignNodeToStudent(
        studentId: _studentIdCtrl.text.trim(),
        nodeId: widget.nodeId,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('배정 실패: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('커리큘럼 배정'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '항목: ${widget.nodeTitle}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _studentIdCtrl,
                decoration: const InputDecoration(
                  labelText: '학생 ID (uuid)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '학생 ID를 입력하세요' : null,
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '※ 다음 버전에서 검색/선택 UI 제공 예정',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: const Icon(Icons.check),
          label: _busy ? const Text('배정 중...') : const Text('배정'),
        ),
      ],
    );
  }
}
