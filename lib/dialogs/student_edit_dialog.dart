import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/services/student_service.dart';

class StudentEditDialog extends StatefulWidget {
  final Student? student;
  final VoidCallback onRefresh;

  const StudentEditDialog({super.key, this.student, required this.onRefresh});

  @override
  State<StudentEditDialog> createState() => _StudentEditDialogState();
}

class _StudentEditDialogState extends State<StudentEditDialog> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController nameController;
  late TextEditingController schoolController;
  late TextEditingController gradeController;
  late TextEditingController phoneController;
  late String gender;
  late bool isAdult;
  late DateTime startDate;

  final StudentService _studentService = StudentService();

  @override
  void initState() {
    super.initState();
    final student = widget.student;
    nameController = TextEditingController(text: student?.name ?? '');
    schoolController = TextEditingController(text: student?.schoolName ?? '');
    gradeController = TextEditingController(
      text: student != null ? student.grade.toString() : '',
    );
    phoneController = TextEditingController(text: student?.phoneNumber ?? '');
    gender = student?.gender ?? '남';
    isAdult = student?.isAdult ?? false;
    startDate = student?.startDate ?? DateTime.now();
  }

  void handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    final student = Student(
      id: widget.student?.id ?? '',
      name: nameController.text.trim(),
      gender: gender,
      isAdult: isAdult,
      schoolName: isAdult ? '' : schoolController.text.trim(),
      grade: isAdult ? 0 : int.tryParse(gradeController.text) ?? 0,
      phoneNumber: phoneController.text.trim(),
      startDate: startDate,
      teacherId: widget.student?.teacherId ?? '',
      memo: widget.student?.memo ?? '',
    );

    if (widget.student == null) {
      await _studentService.addStudent(student);
    } else {
      await _studentService.updateStudent(student);
    }

    if (!mounted) return;
    widget.onRefresh();
    Navigator.of(context).pop();
  }

  void pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => startDate = picked);
  }

  Widget buildToggleButton(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.blue : Colors.grey.shade300,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('📝 학생 정보 수정'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '이름'),
                validator:
                    (value) => value!.trim().isEmpty ? '이름을 입력해주세요' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: RadioListTile(
                      title: const Text('남'),
                      value: '남',
                      groupValue: gender,
                      onChanged: (val) => setState(() => gender = val!),
                    ),
                  ),
                  Expanded(
                    child: RadioListTile(
                      title: const Text('여'),
                      value: '여',
                      groupValue: gender,
                      onChanged: (val) => setState(() => gender = val!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: phoneController,
                decoration: const InputDecoration(
                  labelText: '전화번호 (예: 010-1234-5678)',
                ),
                validator:
                    (value) => value!.trim().isEmpty ? '전화번호를 입력해주세요' : null,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('등록일: '),
                  Text(DateFormat('yyyy.MM.dd').format(startDate)),
                  IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: pickDate,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  buildToggleButton('🧑‍🎓 학생', !isAdult, () {
                    setState(() => isAdult = false);
                  }),
                  buildToggleButton('👤 성인', isAdult, () {
                    setState(() => isAdult = true);
                  }),
                ],
              ),
              if (!isAdult) ...[
                const SizedBox(height: 12),
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
