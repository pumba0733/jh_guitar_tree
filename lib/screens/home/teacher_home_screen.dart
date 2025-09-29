// lib/screens/home/teacher_home_screen.dart
// v1.32.2 | use_build_context_synchronously & control_flow_in_finally 정밀 해소
// - setState 가드: mounted 사용
// - Navigator/ScaffoldMessenger 등 context 의존 호출: context.mounted 가드
// - finally 블록: return 제거(조건부 setState만 수행) → control_flow_in_finally 해소
// - 나머지 동작/라우팅/버튼 구성은 v1.32.0과 동일

import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../services/lesson_service.dart';
import '../../services/student_service.dart';
import '../../models/lesson.dart';
import '../../routes/app_routes.dart';

class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});

  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen> {
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

      // await 이후 state 변경 → State.mounted로 가드
      if (!mounted) return;
      setState(() => _role = role);

      if (!(role == UserRole.teacher || role == UserRole.admin)) {
        // 학생이면 학생 홈으로
        if (!context.mounted) return;
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil(AppRoutes.studentHome, (_) => false);
        return;
      }
    } catch (_) {
      // 역할 판정 실패 시 게스트 취급 (버튼 노출 최소화)
    }
    await _load();
  }

  Future<void> _load() async {
    // setState는 동기이므로 바로 호출 (State.mounted 필요 없음: 현재 동기 컨텍스트)
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final user = AuthService().currentTeacher;
      if (user == null) {
        if (!mounted) return;
        setState(() {
          _today = const [];
          _studentNames = const {};
          _error = '세션이 만료되었거나 사용자 정보가 없습니다.';
        });
        return;
      }

      final data = await _lessonSvc.listTodayByTeacher(user.id);

      // 학생 이름 맵 구성 (id -> name)
      final ids = data
          .map((e) => e.studentId)
          .where((s) => s.trim().isNotEmpty)
          .toSet()
          .toList();
      final nameMap = await _studentSvc.fetchNamesByIds(ids);

      if (!mounted) return;
      setState(() {
        _today = data;
        _studentNames = nameMap;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      // ⚠️ return 사용 금지: control_flow_in_finally 경고 해소
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refresh() async => _load();

  // ===== 학생 선택 & 라우팅 유틸 =====

  Future<String?> _pickStudentId() async {
    final ids = _today
        .map((e) => e.studentId)
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList();

    if (ids.isEmpty) {
      if (!context.mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('오늘 수업 목록에서 학생을 찾을 수 없습니다.')),
      );
      return null;
    }
    if (ids.length == 1) return ids.first;

    if (!context.mounted) return null;
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
    // Navigator를 먼저 캡처 → await 이후 context 직접 접근 회피
    final nav = Navigator.of(context);
    final teacherId = AuthService().currentTeacher?.id;
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

  void _goManageStudents() {
    Navigator.pushNamed(context, AppRoutes.manageStudents);
  }

  @override
  Widget build(BuildContext context) {
    final canSeeLogs = _isTeacherOrAdmin;

    return Scaffold(
      appBar: AppBar(
        title: const Text('강사 홈'),
        actions: [
          if (canSeeLogs)
            IconButton(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.logs),
              icon: const Icon(Icons.list_alt),
              tooltip: '로그',
            ),
          IconButton(
            onPressed: () async {
              await AuthService().signOutAll();
              if (!context.mounted) return; // await 이후 가드
              Navigator.of(
                context,
              ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
            },
            icon: const Icon(Icons.logout),
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: Padding(
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
            // ✅ 추가: 내 학생 관리 (설계서 정합)
            if (_isTeacherOrAdmin)
              ElevatedButton.icon(
                onPressed: _goManageStudents,
                icon: const Icon(Icons.people),
                label: const Text('내 학생 관리'),
              ),
            OutlinedButton.icon(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('새로고침'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
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
        separatorBuilder: (_, _) => const Divider(height: 1),
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
                  'teacherId': AuthService().currentTeacher?.id,
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
