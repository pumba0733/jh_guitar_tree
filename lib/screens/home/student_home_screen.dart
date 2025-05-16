import 'package:flutter/material.dart';

class StudentHomeScreen extends StatelessWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('📚 학생 홈')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.today),
              label: const Text('오늘 수업 보기'),
              onPressed: () => Navigator.pushNamed(context, '/today_lesson'),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.history),
              label: const Text('지난 수업 복습'),
              onPressed: () => Navigator.pushNamed(context, '/lesson_history'),
            ),
          ],
        ),
      ),
    );
  }
}
