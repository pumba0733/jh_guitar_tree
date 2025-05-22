import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/services/student_service.dart';
import 'package:jh_guitar_tree/dialogs/edit_memo_dialog.dart';
import 'package:jh_guitar_tree/dialogs/student_edit_dialog.dart';
import 'package:jh_guitar_tree/services/auth_service.dart';

class StudentListTile extends StatelessWidget {
  final Student student;
  final VoidCallback onRefresh;

  const StudentListTile({
    super.key,
    required this.student,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final isAdmin = AuthService().isAdmin;
    final role = AuthService().currentUserRole ?? '';

    return ListTile(
      title: Text(student.name),
      subtitle: Text('담당: ${student.teacherId} / 메모: ${student.memo}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: '학생 수정',
            onPressed: () {
              showDialog(
                context: context,
                builder:
                    (context) => StudentEditDialog(
                      student: student,
                      isAdmin: isAdmin,
                      role: role,
                      onRefresh: onRefresh,
                    ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.note_alt_outlined),
            tooltip: '메모 수정',
            onPressed: () async {
              final newMemo = await showDialog<String>(
                context: context,
                builder:
                    (context) => EditMemoDialog(
                      studentId: student.id,
                      initialMemo: student.memo,
                    ),
              );
              if (newMemo != null) onRefresh();
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
