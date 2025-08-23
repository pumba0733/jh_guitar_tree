// lib/screens/home/teacher_home_screen.dart
// v1.08 | 강사용 퀵뷰(오늘 수업) + 로그아웃 호출 수정(logoutAll)
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/teacher_service.dart';
import '../../services/student_service.dart';
import '../../services/lesson_service.dart';
import '../../models/lesson.dart';

class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});

  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen> {
  final _teacherSvc = TeacherService();
  final _lessonSvc = LessonService();
  final _studentSvc = StudentService();

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentAuthUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('강사 홈'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => AuthService().logoutAll(), // ← ✅ 인자 제거
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: user == null
          ? const Center(child: Text('로그인 필요'))
          : FutureBuilder<_TodayData?>(
              future: _buildTodayData(user.email ?? ''),
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snap.data;
                if (data == null || data.teacherId == null) {
                  return _TeacherMappingHint(email: user.email ?? '(알수없음)');
                }
                final lessons = data.lessons;
                final names = data.nameById;
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '오늘 수업 (${lessons.length}건)',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      if (lessons.isEmpty)
                        const Text('아직 기록이 없어요. 학생 선택 후 오늘 수업을 시작하세요.')
                      else
                        Expanded(
                          child: ListView.separated(
                            itemCount: lessons.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final l = lessons[i];
                              final name = names[l.studentId] ?? l.studentId;
                              return ListTile(
                                leading: const Icon(Icons.school),
                                title: Text(name),
                                subtitle: Text(
                                  (l.subject?.isNotEmpty == true)
                                      ? l.subject!
                                      : '(제목 없음)',
                                ),
                                trailing: Text(
                                  l.date.toIso8601String().substring(0, 10),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<_TodayData?> _buildTodayData(String email) async {
    if (email.trim().isEmpty) return null;
    final t = await _teacherSvc.getByEmail(email);
    if (t == null) return const _TodayData(null, [], {});
    final lessons = await _lessonSvc.listTodayByTeacher(t.id);
    final ids = {for (final l in lessons) l.studentId};
    final names = await _studentSvc.fetchNamesByIds(ids);
    return _TodayData(t.id, lessons, names);
  }
}

class _TodayData {
  final String? teacherId;
  final List<Lesson> lessons;
  final Map<String, String> nameById;
  const _TodayData(this.teacherId, this.lessons, this.nameById);
}

class _TeacherMappingHint extends StatelessWidget {
  final String email;
  const _TeacherMappingHint({required this.email}); // ← ✅ super.key 제거

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        '강사 계정이 teachers 테이블과 아직 연결되지 않았어요.\n\n'
        '• 이메일: $email\n'
        '• 조치: teachers 테이블에 이 이메일과 auth_user_id(선택)를 등록해주세요.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}
