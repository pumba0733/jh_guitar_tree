// lib/screens/home/student_home_screen.dart
// v1.44.0 | 작성일: 2025-09-08 | 작성자: GPT
// 변경점:
// - "나의 커리큘럼" 진입 버튼 추가 (StudentCurriculumScreen로 이동)
// - 라우팅 시 arguments로 studentId 전달 (정책 일관)

import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen> {
  late final AuthService _auth;

  @override
  void initState() {
    super.initState();
    _auth = AuthService();

    // 로그인 가드: 첫 프레임 이후 검사
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final stu = _auth.currentStudent;
      if (stu == null) {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final stu = _auth.currentStudent;

    return Scaffold(
      appBar: AppBar(
        title: Text('학생 홈${stu?.name != null ? ' - ${stu!.name}' : ''}'),
        actions: [
          IconButton(
            tooltip: '로그아웃',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await _auth.signOutAll();
              if (!context.mounted) return;
              Navigator.of(
                context,
              ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
            },
          ),
        ],
      ),
      body: Center(
        child: stu == null
            ? const Text('학생 세션이 없습니다. 다시 로그인 해주세요.')
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      // 📝 오늘 수업
                      Tooltip(
                        message: '오늘 수업으로 바로 이동',
                        child: FilledButton.icon(
                          icon: const Icon(Icons.today),
                          label: const Text('오늘 수업'),
                          onPressed: () {
                            Navigator.pushNamed(
                              context,
                              AppRoutes.todayLesson,
                              arguments: {'studentId': stu.id},
                            );
                          },
                        ),
                      ),

                      // 📚 지난 수업 복습
                      Tooltip(
                        message: '지난 수업 기록 보기',
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.history),
                          label: const Text('지난 수업 복습'),
                          onPressed: () {
                            Navigator.pushNamed(
                              context,
                              AppRoutes.lessonHistory,
                              arguments: {'studentId': stu.id},
                            );
                          },
                        ),
                      ),

                      // 🧾 수업 요약 (학생용 조회 전용)
                      Tooltip(
                        message: '최근 수업 요약 보기',
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.summarize),
                          label: const Text('수업 요약'),
                          onPressed: () {
                            Navigator.pushNamed(
                              context,
                              AppRoutes.summaryResult,
                              arguments: {
                                'studentId': stu.id,
                                'asStudent': true,
                              },
                            );
                          },
                        ),
                      ),

                      // 📖 나의 커리큘럼
                      Tooltip(
                        message: '배정된 커리큘럼 보기',
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.menu_book),
                          label: const Text('나의 커리큘럼'),
                          onPressed: () {
                            Navigator.pushNamed(
                              context,
                              AppRoutes.studentCurriculum,
                              arguments: {'studentId': stu.id},
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
