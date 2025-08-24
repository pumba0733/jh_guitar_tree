// lib/screens/home/teacher_home_screen.dart
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/lesson_service.dart';
import '../../models/lesson.dart';
import '../../routes/app_routes.dart';

class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});

  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen> {
  final _svc = LessonService();
  List<Lesson> _today = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = AuthService().currentAuthUser;
    if (user == null) {
      setState(() {
        _today = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final data = await _svc.listTodayByTeacher(user.id);
      setState(() => _today = data);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService();
    return Scaffold(
      appBar: AppBar(
        title: const Text('강사 홈'),
        actions: [
          IconButton(
            onPressed: () => Navigator.pushNamed(context, AppRoutes.logs),
            icon: const Icon(Icons.list_alt),
            tooltip: '로그',
          ),
          IconButton(
            onPressed: () async {
              await auth.signOutAll();
              if (context.mounted) {
                Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
              }
            },
            icon: const Icon(Icons.logout),
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _today.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (_, i) {
                final l = _today[i];
                return ListTile(
                  title: Text(l.subject ?? '(제목 없음)'),
                  subtitle: Text('학생ID: ${l.studentId}  날짜: ${l.date.toIso8601String().split("T").first}'),
                );
              },
            ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          children: [
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.lessonSummary),
              icon: const Icon(Icons.summarize),
              label: const Text('수업 요약'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.lessonHistory),
              icon: const Icon(Icons.history),
              label: const Text('지난 수업 복습'),
            ),
          ],
        ),
      ),
    );
  }
}
