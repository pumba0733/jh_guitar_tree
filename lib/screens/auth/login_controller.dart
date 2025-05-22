import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/screens/home/student_home_screen.dart';
import 'package:jh_guitar_tree/dialogs/student_selector_dialog.dart';

class LoginController {
  final BuildContext context;

  LoginController(this.context);

  /// 학생 이름 검색 및 로그인 시도
  Future<void> handleStudentLogin(String name) async {
    if (name.isEmpty) return;

    try {
      final matches = await _findStudentsByName(name);

      if (matches.isEmpty) {
        _showErrorDialog('해당 이름의 학생이 없습니다.');
      } else if (matches.length == 1) {
        _navigateToHome(matches.first);
      } else {
        _showDuplicateDialog(matches);
      }
    } catch (e) {
      _showErrorDialog('네트워크 오류가 발생했습니다. 다시 시도해주세요.');
    }
  }

  /// Firestore에서 이름으로 학생 찾기
  Future<List<Student>> _findStudentsByName(String name) async {
    final snapshot =
        await FirebaseFirestore.instance
            .collection('students')
            .where('name', isEqualTo: name)
            .get();

    return snapshot.docs
        .map((doc) => Student.fromJson(doc.data(), doc.id))
        .toList();
  }

  /// 학생 홈 화면으로 이동
  void _navigateToHome(Student student) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => StudentHomeScreen(student: student)),
    );
  }

  /// 동명이인 선택 다이얼로그 호출
  void _showDuplicateDialog(List<Student> students) {
    showDialog(
      context: context,
      builder:
          (_) => StudentSelectorDialog(
            students: students,
            onStudentSelected: _navigateToHome,
          ),
    );
  }

  /// 오류 다이얼로그
  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('오류'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('확인'),
              ),
            ],
          ),
    );
  }
}
