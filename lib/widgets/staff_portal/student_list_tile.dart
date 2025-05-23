import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/services/student_service.dart';
import 'package:jh_guitar_tree/dialogs/edit_memo_dialog.dart';
import 'package:jh_guitar_tree/dialogs/student_edit_dialog.dart';

class StudentListTile extends StatelessWidget {
  final Student student;
  final VoidCallback onRefresh;
  final List<Student> allStudents; // ✅ 추가됨

  const StudentListTile({
    super.key,
    required this.student,
    required this.onRefresh,
    required this.allStudents,
  });

  String getLast4Digits(String phoneNumber) {
    return phoneNumber.length >= 4
        ? phoneNumber.substring(phoneNumber.length - 4)
        : '****';
  }

  String getDisplayName(Student student, List<Student> all) {
    final dupes = all.where((s) => s.name == student.name).toList();
    if (dupes.length > 1) {
      return '${student.name} (${getLast4Digits(student.phoneNumber)})';
    } else {
      return student.name;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(getDisplayName(student, allStudents)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.note),
            tooltip: '메모 수정',
            onPressed: () {
              showDialog(
                context: context,
                builder:
                    (_) => EditMemoDialog(
                      studentId: student.id,
                      initialMemo: student.memo,
                    ),
              ).then((_) => onRefresh());
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: '학생 정보 수정',
            onPressed: () {
              showDialog(
                context: context,
                builder:
                    (_) => StudentEditDialog(
                      student: student,
                      onRefresh: onRefresh,
                    ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: '삭제',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder:
                    (_) => AlertDialog(
                      title: const Text('학생 삭제'),
                      content: const Text('정말 삭제하시겠습니까?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('취소'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('삭제'),
                        ),
                      ],
                    ),
              );
              if (confirm == true) {
                await StudentService().deleteStudent(student.id);
                onRefresh();
              }
            },
          ),
        ],
      ),
    );
  }
}
