import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/services/student_service.dart';
import 'package:jh_guitar_tree/services/auth_service.dart';

class StudentEditDialog extends StatefulWidget {
  final Student? student;
  final bool isAdmin;
  final String role;
  final VoidCallback onRefresh;

  const StudentEditDialog({
    super.key,
    this.student,
    required this.isAdmin,
    required this.role,
    required this.onRefresh,
  });

  @override
  State<StudentEditDialog> createState() => _StudentEditDialogState();
}

class _StudentEditDialogState extends State<StudentEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController nameController;
  late TextEditingController schoolController;
  late TextEditingController gradeController;
  late TextEditingController phoneSuffixController;
  late TextEditingController memoController;

  String gender = '남';
  bool isAdult = false;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.student?.name ?? '');
    schoolController = TextEditingController(
      text: widget.student?.schoolName ?? '',
    );
    gradeController = TextEditingController(
      text:
          widget.student?.grade != null ? widget.student!.grade.toString() : '',
    );
    phoneSuffixController = TextEditingController(
      text: widget.student?.phoneSuffix ?? '',
    );
    memoController = TextEditingController(text: widget.student?.memo ?? '');

    gender = widget.student?.gender ?? '남';
    isAdult = widget.student?.isAdult ?? false;
  }

  void handleSave() async {
    if (_formKey.currentState!.validate()) {
      final newStudent = Student(
        id: widget.student?.id ?? '',
        name: nameController.text.trim(),
        gender: gender,
        isAdult: isAdult,
        schoolName: isAdult ? '' : schoolController.text.trim(),
        grade: isAdult ? 0 : int.tryParse(gradeController.text.trim()) ?? 0,
        startDate:
            widget.student?.startDate ?? DateTime.now().toIso8601String(),
        teacherId:
            widget.student?.teacherId ?? (AuthService().currentUserId ?? ''),
        memo: memoController.text.trim(),
        phoneSuffix: phoneSuffixController.text.trim(),
      );

      if (widget.student == null) {
        await StudentService().addStudent(newStudent);
      } else {
        await StudentService().updateStudent(newStudent);
      }

      widget.onRefresh();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.student == null ? '학생 등록' : '학생 수정'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '이름'),
                validator:
                    (value) =>
                        value == null || value.trim().isEmpty
                            ? '이름을 입력해주세요'
                            : null,
              ),
              TextFormField(
                controller: phoneSuffixController,
                decoration: const InputDecoration(labelText: '전화번호 뒷자리'),
                keyboardType: TextInputType.number,
                validator:
                    (value) =>
                        value == null || value.length != 4 ? '4자리 입력' : null,
              ),
              DropdownButtonFormField<String>(
                value: gender,
                decoration: const InputDecoration(labelText: '성별'),
                items: const [
                  DropdownMenuItem(value: '남', child: Text('남')),
                  DropdownMenuItem(value: '여', child: Text('여')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => gender = value);
                },
              ),
              CheckboxListTile(
                value: isAdult,
                onChanged: (value) {
                  if (value != null) setState(() => isAdult = value);
                },
                title: const Text('성인'),
              ),
              if (!isAdult) ...[
                TextFormField(
                  controller: schoolController,
                  decoration: const InputDecoration(labelText: '학교'),
                ),
                TextFormField(
                  controller: gradeController,
                  decoration: const InputDecoration(labelText: '학년'),
                  keyboardType: TextInputType.number,
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: memoController,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '메모'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        ElevatedButton(onPressed: handleSave, child: const Text('저장')),
      ],
    );
  }
}
