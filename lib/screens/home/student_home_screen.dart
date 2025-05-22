// 📄 lib/screens/home/student_home_screen.dart

import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/ui/layout/base_scaffold.dart';

class StudentHomeScreen extends StatelessWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: '학생 홈',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: () {
              // 오늘 수업 보기로 이동
            },
            child: const Text('📝 오늘 수업 보기'),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () {
              // 지난 수업 복습으로 이동
            },
            child: const Text('📚 지난 수업 복습'),
          ),
        ],
      ),
    );
  }
}
