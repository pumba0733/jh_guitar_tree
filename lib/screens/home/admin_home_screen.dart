import 'package:flutter/material.dart';

class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('👑 관리자 홈')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ListView(
          children: [
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/today_lesson'),
              child: const Text('오늘 수업'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/lesson_history'),
              child: const Text('지난 수업 복습'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/lesson_summary'),
              child: const Text('수업 요약'),
            ),
            const Divider(),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/manage_students'),
              child: const Text('학생 관리'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/manage_teachers'),
              child: const Text('강사 관리'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/manage_keywords'),
              child: const Text('키워드 관리'),
            ),
            ElevatedButton(
              onPressed:
                  () => Navigator.pushNamed(context, '/manage_curriculum'),
              child: const Text('커리큘럼 관리'),
            ),
            const Divider(),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/logs'),
              child: const Text('📜 로그 보기'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/export'),
              child: const Text('백업 내보내기'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pushNamed(context, '/import'),
              child: const Text('백업 불러오기'),
            ),
          ],
        ),
      ),
    );
  }
}
