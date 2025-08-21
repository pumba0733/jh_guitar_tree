// lib/screens/home/student_home_screen.dart
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';
import '../../models/student.dart';

class StudentHomeScreen extends StatelessWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService();

    return Scaffold(
      appBar: AppBar(
        title: const Text('학생 홈'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '로그아웃',
            onPressed: () async {
              await auth.logoutAll();
              if (context.mounted) {
                Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 환영 문구: Student 변경에 즉시 반응
              ValueListenableBuilder<Student?>(
                valueListenable: auth.currentStudent,
                builder: (context, student, _) {
                  final title = student == null
                      ? '학생 정보 없음'
                      : '환영합니다, ${student.name}님!';
                  return Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),

              // 오늘 수업 보기
              FilledButton.icon(
                onPressed: () {
                  Navigator.pushNamed(context, AppRoutes.todayLesson);
                },
                icon: const Text('📝', style: TextStyle(fontSize: 18)),
                label: const Text('오늘 수업 보기'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
              ),
              const SizedBox(height: 12),

              // 지난 수업 복습
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pushNamed(context, AppRoutes.lessonHistory);
                },
                icon: const Text('📚', style: TextStyle(fontSize: 18)),
                label: const Text('지난 수업 복습'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
              ),

              const Spacer(),

              // 저장/상태 안내 자리(향후 자동저장 UI 들어올 영역)
              const Opacity(
                opacity: 0.6,
                child: Text(
                  'Tip: 상단 로그아웃 아이콘으로 계정 전환이 가능해요.',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
