// lib/screens/home/student_home_screen.dart
// v1.44.2 | 관리자 진입시 studentId 기반으로 학생 로드

import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/student_service.dart';
import '../../routes/app_routes.dart';
import '../../models/student.dart';

class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen> {
  late final AuthService _auth;
  final _studentSvc = StudentService();

  String? _argStudentId;
  bool _adminDrive = false;

  Student? _student;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _auth = AuthService();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      // arguments 확인
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        _argStudentId = args['studentId'] as String?;
        _adminDrive = args['adminDrive'] == true;
      }

      if (_adminDrive && _argStudentId != null) {
        // 관리자 모드: Supabase에서 해당 학생 정보 직접 로드
        try {
          final s = await _studentSvc.fetchById(_argStudentId!);
          if (mounted) setState(() => _student = s);
        } catch (_) {
          // 에러 무시, 화면에 메시지 표시
        } finally {
          if (mounted) setState(() => _loading = false);
        }
      } else {
        // 학생 로그인 모드
        final stu = _auth.currentStudent;
        if (stu == null) {
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
        } else {
          setState(() {
            _student = stu;
            _loading = false;
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '학생 홈${_student?.name != null ? ' - ${_student!.name}' : ''}',
        ),
        actions: [
          if (!_adminDrive)
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
        child: _student == null
            ? const Text('학생 정보를 찾을 수 없습니다.')
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
                      FilledButton.icon(
                        icon: const Icon(Icons.today),
                        label: const Text('오늘 수업'),
                        onPressed: () {
                          AppRoutes.pushTodayLesson(
                            context,
                            studentId: _student!.id,
                          );
                        },
                      ),
                      // 📚 지난 수업 복습
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.history),
                        label: const Text('지난 수업 복습'),
                        onPressed: () {
                          AppRoutes.pushLessonHistory(
                            context,
                            studentId: _student!.id,
                          );
                        },
                      ),
                      // 🧾 수업 요약
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.summarize),
                        label: const Text('수업 요약'),
                        onPressed: () {
                          AppRoutes.pushLessonSummary(
                            context,
                            studentId: _student!.id,
                          );
                        },
                      ),
                      // 📖 나의 커리큘럼
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.menu_book),
                        label: const Text('나의 커리큘럼'),
                        onPressed: () {
                          AppRoutes.pushStudentCurriculum(
                            context,
                            studentId: _student!.id,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
