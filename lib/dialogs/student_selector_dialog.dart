import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/student.dart';

class StudentSelectorDialog extends StatelessWidget {
  final List<Student> students;
  final void Function(Student) onStudentSelected;

  const StudentSelectorDialog({
    super.key,
    required this.students,
    required this.onStudentSelected,
  });

  String getLast4Digits(String phoneNumber) {
    return phoneNumber.length >= 4
        ? phoneNumber.substring(phoneNumber.length - 4)
        : '****';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('학생 선택'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children:
            students.map((student) {
              final suffix = getLast4Digits(student.phoneNumber);
              return ListTile(
                title: Text('${student.name} ($suffix)'),
                onTap: () {
                  Navigator.pop(context);
                  onStudentSelected(student);
                },
              );
            }).toList(),
      ),
    );
  }
}
