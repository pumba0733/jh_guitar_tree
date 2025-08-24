// lib/screens/home/student_home_screen.dart
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

class StudentHomeScreen extends StatelessWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService();
    final stu = auth.currentStudent;

    return Scaffold(
      appBar: AppBar(
        title: Text('학생 홈 - ${stu?.name ?? ""}'),
        actions: [
          IconButton(
            onPressed: () async {
              await auth.signOutAll();
              if (context.mounted) {
                Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
              }
            },
            icon: const Icon(Icons.logout),
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: Center(
        child: stu == null
            ? const Text("학생 세션이 없습니다. 다시 로그인 해주세요.")
            : Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      AppRoutes.todayLesson,
                      arguments: {'studentId': stu.id},
                    ),
                    icon: const Icon(Icons.today),
                    label: const Text('오늘 수업'),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      AppRoutes.lessonHistory,
                      arguments: {'studentId': stu.id},
                    ),
                    icon: const Icon(Icons.history),
                    label: const Text('지난 수업 복습'),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      AppRoutes.lessonSummary,
                      arguments: {'studentId': stu.id},
                    ),
                    icon: const Icon(Icons.summarize),
                    label: const Text('수업 요약'),
                  ),
                ],
              ),
      ),
    );
  }
}
