// 파일: lib/screens/auth/login_controller.dart

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
    final cleanName = name.trim().toLowerCase();
    if (cleanName.isEmpty) return;

    try {
      final matches = await _findStudentsByName(cleanName);

      if (matches.isEmpty) {
        _showErrorDialog('해당 이름의 학생이 없습니다.');
      } else if (matches.length == 1) {
        _navigateToHome(matches.first);
      } else {
        _showDuplicateDialog(matches);
      }
    } catch (e) {
      print('❌ 로그인 오류: \$e');
      _showErrorDialog('네트워크 오류가 발생했습니다. 다시 시도해주세요.');
    }
  }

  /// Firestore에서 이름으로 학생 찾기 (name_lowercase 필드 사용)
  Future<List<Student>> _findStudentsByName(String name) async {
    final snapshot =
        await FirebaseFirestore.instance
            .collection('students')
            .where('name_lowercase', isEqualTo: name)
            .get();

    print('🧾 Firestore 검색된 문서 수: \${snapshot.docs.length}');
    return snapshot.docs
        .map((doc) => Student.fromJson(doc.data(), doc.id))
        .toList();
  }

  void _navigateToHome(Student student) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => StudentHomeScreen(student: student)),
    );
  }

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
