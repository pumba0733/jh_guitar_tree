// lib/screens/home/widgets/teacher_home_body.dart
// v1.32.0 | 강사/관리자 공용 홈 바디

import 'package:flutter/material.dart';
import '../../../services/auth_service.dart';
import '../../../services/lesson_service.dart';
import '../../../services/student_service.dart';
import '../../../models/lesson.dart';
import '../../../routes/app_routes.dart';

class TeacherHomeBody extends StatefulWidget {
  const TeacherHomeBody({super.key});

  @override
  State<TeacherHomeBody> createState() => _TeacherHomeBodyState();
}

class _TeacherHomeBodyState extends State<TeacherHomeBody> {
  final _lessonSvc = LessonService();
  final _studentSvc = StudentService();

  List<Lesson> _today = const [];
  Map<String, String> _studentNames = const {}; // id -> name
  bool _loading = true;
  String? _error;
  UserRole? _role;

  bool get _isTeacherOrAdmin =>
      _role == UserRole.teacher || _role == UserRole.admin;

  @override
  void initState() {
    super.initState();
    _guardAndLoad();
  }

  Future<void> _guardAndLoad() async {
    try {
      final role = await AuthService().getRole();
      if (!mounted) return;
      setState(() => _role = role);
    } catch (_) {
      if (!mounted) return;
      setState(() => _role = null);
    }
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final user = AuthService().currentAuthUser;
      if (user == null) {
        setState(() {
          _today = const [];
          _studentNames = const {};
          _error = '세션이 만료되었거나 사용자 정보가 없습니다.';
        });
        return;
      }

      final data = await _lessonSvc.listTodayByTeacher(user.id);
      final ids = data
          .map((e) => e.studentId)
          .where((s) => s.trim().isNotEmpty)
          .toSet()
          .toList();
      final nameMap = await _studentSvc.fetchNamesByIds(ids);

      setState(() {
        _today = data;
        _studentNames = nameMap;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async => _load();

  Future<String?> _pickStudentId() async {
    final ids = _today
        .map((e) => e.studentId)
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList();

    if (ids.isEmpty) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('오늘 수업 목록에서 학생을 찾을 수 없습니다.')),
      );
      return null;
    }
    if (ids.length == 1) return ids.first;

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetCtx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text('학생 선택'),
                subtitle: Text('요약/복습할 학생을 선택하세요'),
              ),
              const Divider(height: 1),
              ...ids.map((id) {
                final name = _studentNames[id] ?? id;
                return ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(name),
                  subtitle: name == id ? const Text('학생ID로 표시됨') : null,
                  onTap: () => Navigator.pop(sheetCtx, id),
                );
              }),
            ],
          ),
        );
      },
    );
    return selected;
  }

  Future<void> _goLessonSummary() async {
    final nav = Navigator.of(context);
    final teacherId = AuthService().currentAuthUser?.id;
    final studentId = await _pickStudentId();
    if (studentId == null) return;
    nav.pushNamed(
      AppRoutes.lessonSummary,
      arguments: {
        'studentId': studentId,
        if (teacherId != null) 'teacherId': teacherId,
      },
    );
  }

  Future<void> _goLessonHistory() async {
    final nav = Navigator.of(context);
    final studentId = await _pickStudentId();
    if (studentId == null) return;
    nav.pushNamed(AppRoutes.lessonHistory, arguments: {'studentId': studentId});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _buildList()),
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              if (_isTeacherOrAdmin)
                ElevatedButton.icon(
                  onPressed: _goLessonSummary,
                  icon: const Icon(Icons.summarize),
                  label: const Text('수업 요약'),
                ),
              ElevatedButton.icon(
                onPressed: _goLessonHistory,
                icon: const Icon(Icons.history),
                label: const Text('지난 수업 복습'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('새로고침'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(
        message: '오늘 수업을 불러오지 못했습니다.\n$_error',
        onRetry: _refresh,
      );
    }
    if (_today.isEmpty) {
      return _EmptyView(onRetry: _refresh);
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _today.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '오늘 수업 (${_today.length}건)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            );
          }
          final l = _today[i - 1];
          final dateStr = l.date.toIso8601String().split('T').first;
          final displayName =
              _studentNames[l.studentId] ?? '학생ID: ${l.studentId}';

          return ListTile(
            leading: const Icon(Icons.event_note),
            title: Text(
              (l.subject?.trim().isNotEmpty ?? false)
                  ? l.subject!.trim()
                  : '(제목 없음)',
            ),
            subtitle: Text('$displayName  ·  날짜: $dateStr'),
            onTap: () {
              Navigator.pushNamed(
                context,
                AppRoutes.todayLesson,
                arguments: {
                  'studentId': l.studentId,
                  if ((l.id).trim().isNotEmpty) 'lessonId': l.id,
                  'teacherId': AuthService().currentAuthUser?.id,
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final Future<void> Function() onRetry;
  const _EmptyView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox, size: 42),
            const SizedBox(height: 8),
            const Text('오늘 등록된 수업이 없습니다.'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('새로고침'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 42),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}
