import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/screens/auth/login_screen.dart';
import 'package:jh_guitar_tree/ui/layout/base_scaffold.dart';

class StudentHomeScreen extends StatelessWidget {
  final Student student;

  const StudentHomeScreen({super.key, required this.student});

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: '${student.name}님, 반가워요! 🎸',
      actions: [
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: '로그아웃',
          onPressed: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            );
          },
        ),
      ],
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 📒 오늘 수업 보기
            ElevatedButton.icon(
              icon: const Icon(Icons.edit_note),
              label: const Text('📒 오늘 수업 보기'),
              onPressed: () {
                // TODO: 오늘 수업 화면으로 이동 (student 전달 예정)
              },
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(240, 60),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(height: 20),

            // 📚 지난 수업 복습
            ElevatedButton.icon(
              icon: const Icon(Icons.menu_book),
              label: const Text('📚 지난 수업 복습'),
              onPressed: () {
                // TODO: 복습 화면으로 이동 (student 전달 예정)
              },
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(240, 60),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
            const SizedBox(height: 20),

            // 📑 커리큘럼 보기
            ElevatedButton.icon(
              icon: const Icon(Icons.account_tree),
              label: const Text('📑 커리큘럼 보기'),
              onPressed: () {
                // TODO: 커리큘럼 화면으로 이동
              },
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(240, 60),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
