// lib/screens/home/widgets/teacher_home_body.dart
// v1.33.4-ui2-safe-scroll-teacherStudents
// - Supabase in-filter: .in_() -> .inFilter('col', values)
// - 미사용 필드 _myStudentIds 제거

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  final _sp = Supabase.instance.client;

  List<Lesson> _today = const [];
  Map<String, String> _studentNames = const {}; // 오늘 수업용 id->name

  // 오늘/최근
  List<String> _todayStudentIds = const [];
  List<String> _recentStudentIds = const [];
  Map<String, String> _recentStudentNames = const {};

  // 최근 14일(오늘 포함) 중복 제거 + 최신일 정렬 상위 50
  List<_RecentStudent> _recent14Unique = const [];
  Map<String, String> _recent14Names = const {};

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
          _todayStudentIds = const [];
          _recentStudentIds = const [];
          _recentStudentNames = const {};
          _recent14Unique = const [];
          _recent14Names = const {};
          _error = '세션이 만료되었거나 사용자 정보가 없습니다.';
        });
        return;
      }

      // ✅ 0) 내 학생 ID 목록(students.teacher_id = me)
      final myStudents = await _fetchMyStudentIds(user.id);

      // 1) 오늘 수업 (기존 RPC 유지)
      final todayList = await _lessonSvc.listTodayByTeacher(user.id);

      final todayIds = todayList
          .map((e) => e.studentId)
          .where((s) => s.trim().isNotEmpty)
          .toSet()
          .toList();

      final nameMapToday = todayIds.isEmpty
          ? <String, String>{}
          : await _studentSvc.fetchNamesByIds(todayIds);

      // 2) 오늘 제외 최근 14일 (내 학생 기준으로 필터링, 12개 제한 - 기존 섹션 유지용)
      final recentIdsOld =
          await _fetchRecentStudentIdsExcludingTodayByMyStudents(
            myStudentIds: myStudents,
            days: 14,
            limit: 12,
            excludeIds: todayIds,
          );
      final nameMapRecentOld = recentIdsOld.isEmpty
          ? <String, String>{}
          : await _studentSvc.fetchNamesByIds(recentIdsOld);

      // 3) 최근 14일(오늘 포함) 최신 수업일 기준 상위 50 (내 학생 기준)
      final recent14 = await _fetchRecentStudentsWithLastDateByMyStudents(
        myStudentIds: myStudents,
        days: 14,
        limit: 50,
      );
      final ids14 = recent14.map((e) => e.studentId).toList();
      final nameMap14 = ids14.isEmpty
          ? <String, String>{}
          : await _studentSvc.fetchNamesByIds(ids14);

      if (!mounted) return;
      setState(() {
        _today = todayList;
        _studentNames = nameMapToday;
        _todayStudentIds = todayIds;

        _recentStudentIds = recentIdsOld;
        _recentStudentNames = nameMapRecentOld;

        _recent14Unique = recent14;
        _recent14Names = nameMap14;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ===== Supabase helpers =====

  /// 내 담당 학생 id 집합 (students.teacher_id = me)
  Future<Set<String>> _fetchMyStudentIds(String teacherId) async {
    final List rows = await _sp
        .from('students')
        .select('id')
        .eq('teacher_id', teacherId);
    final set = <String>{};
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      final id = (m['id'] ?? '').toString();
      if (id.isNotEmpty) set.add(id);
    }
    return set;
  }

  /// 오늘 제외 최근 N일: 내 학생들 중 레슨 존재한 학생 id (중복 제거, 최신순, 상위 limit)
  Future<List<String>> _fetchRecentStudentIdsExcludingTodayByMyStudents({
    required Set<String> myStudentIds,
    required List<String> excludeIds,
    int days = 14,
    int limit = 12,
  }) async {
    if (myStudentIds.isEmpty) return const [];

    final now = DateTime.now();
    final todayDate = DateTime(now.year, now.month, now.day);
    final from = todayDate.subtract(Duration(days: days));

    final List rows = await _sp
        .from('lessons')
        .select('student_id, date')
        .inFilter('student_id', myStudentIds.toList())
        .gte('date', _dateOnly(from))
        .lt('date', _dateOnly(todayDate));

    final Map<String, DateTime> lastByStudent = {};
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      final sid = (m['student_id'] ?? '').toString();
      if (sid.isEmpty) continue;
      final dRaw = (m['date'] ?? '').toString();
      final d = DateTime.tryParse(dRaw);
      if (d == null) continue;
      final prev = lastByStudent[sid];
      if (prev == null || d.isAfter(prev)) {
        lastByStudent[sid] = d;
      }
    }

    for (final ex in excludeIds) {
      lastByStudent.remove(ex);
    }

    final sorted = lastByStudent.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  /// 최근 N일(오늘 포함): 내 학생들 중 최신 수업일을 집계하여 정렬
  Future<List<_RecentStudent>> _fetchRecentStudentsWithLastDateByMyStudents({
    required Set<String> myStudentIds,
    int days = 14,
    int limit = 50,
  }) async {
    if (myStudentIds.isEmpty) return const [];

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = today.subtract(Duration(days: days));

    final List rows = await _sp
        .from('lessons')
        .select('student_id, date')
        .inFilter('student_id', myStudentIds.toList())
        .gte('date', _dateOnly(from));

    final Map<String, DateTime> lastByStudent = {};
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      final sid = (m['student_id'] ?? '').toString();
      if (sid.isEmpty) continue;
      final dRaw = (m['date'] ?? '').toString();
      final d = DateTime.tryParse(dRaw);
      if (d == null) continue;
      final prev = lastByStudent[sid];
      if (prev == null || d.isAfter(prev)) {
        lastByStudent[sid] = d;
      }
    }

    final sorted = lastByStudent.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sorted.take(limit).map((e) {
      return _RecentStudent(studentId: e.key, lastDate: e.value);
    }).toList();
  }

  String _dateOnly(DateTime d) =>
      DateTime(d.year, d.month, d.day).toIso8601String().split('T').first;

  Future<void> _refresh() async => _load();

  // ===== 네비게이션 =====

  Future<void> _openStudentHomeById(String studentId, {String? name}) async {
    if (!mounted) return;
    Navigator.pushNamed(
      context,
      AppRoutes.studentHome,
      arguments: {
        'studentId': studentId,
        if ((name ?? '').trim().isNotEmpty) 'studentName': name!.trim(),
      },
    );
  }

  Future<void> _openStudentEdit(String studentId, {String? name}) async {
    if (!mounted) return;
    Navigator.pushNamed(
      context,
      AppRoutes.manageStudents,
      arguments: {'focusStudentId': studentId, 'prefill': (name ?? '').trim()},
    );
  }

  Future<void> _openLessonHistoryById(String studentId) async {
    if (!mounted) return;
    Navigator.pushNamed(
      context,
      AppRoutes.lessonHistory,
      arguments: {'studentId': studentId},
    );
  }

  // ===== UI =====

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(
        message: '오늘 수업을 불러오지 못했습니다.\n$_error',
        onRetry: _refresh,
      );
    }

    Widget buildTodaySection() {
      if (_today.isEmpty) {
        return _NoTodaySection(
          todayIds: _todayStudentIds,
          todayNames: _studentNames,
          recentIds: _recentStudentIds,
          recentNames: _recentStudentNames,
          onOpenHome: (id) => _openStudentHomeById(
            id,
            name: _studentNames[id] ?? _recentStudentNames[id],
          ),
          onOpenHistory: _openLessonHistoryById,
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Text(
              '오늘 수업 (${_today.length}건)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _today.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final l = _today[i];
              final dateStr = _safeDate(l.date);
              final displayName =
                  _studentNames[l.studentId] ?? '학생ID: ${l.studentId}';
              final subject = _safeSubject(l);
              final lessonId = (l.id).trim();

              return ListTile(
                leading: const Icon(Icons.event_note),
                title: Text(subject),
                subtitle: Text('$displayName  ·  날짜: $dateStr'),
                onTap: () {
                  Navigator.pushNamed(
                    context,
                    AppRoutes.todayLesson,
                    arguments: {
                      'studentId': l.studentId,
                      if (lessonId.isNotEmpty) 'lessonId': lessonId,
                      'teacherId': AuthService().currentAuthUser?.id,
                    },
                  );
                },
              );
            },
          ),
        ],
      );
    }

    Widget buildRecent14Section() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '최근 진행 학생(14일, 최대 50명)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_recent14Unique.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('최근 14일 내 진행한 학생이 없습니다.'),
            )
          else
            _Recent14List(
              list: _recent14Unique,
              nameMap: _recent14Names,
              onOpenHome: (sid) =>
                  _openStudentHomeById(sid, name: _recent14Names[sid]),
              onOpenEdit: (sid) =>
                  _openStudentEdit(sid, name: _recent14Names[sid]),
            ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              buildTodaySection(),
              buildRecent14Section(),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (_isTeacherOrAdmin)
                      ElevatedButton.icon(
                        onPressed: () async {
                          final ids = _todayStudentIds;
                          if (ids.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('오늘 진행 학생이 없습니다.')),
                            );
                            return;
                          }
                          Navigator.pushNamed(
                            context,
                            AppRoutes.lessonSummary,
                            arguments: {
                              'studentId': ids.first,
                              'teacherId': AuthService().currentAuthUser?.id,
                            },
                          );
                        },
                        icon: const Icon(Icons.summarize),
                        label: const Text('수업 요약'),
                      ),
                    ElevatedButton.icon(
                      onPressed: () {
                        final id = (_todayStudentIds.isNotEmpty
                            ? _todayStudentIds.first
                            : (_recentStudentIds.isNotEmpty
                                  ? _recentStudentIds.first
                                  : (_recent14Unique.isNotEmpty
                                        ? _recent14Unique.first.studentId
                                        : '')));
                        if (id.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('최근/오늘 학생이 없습니다.')),
                          );
                          return;
                        }
                        _openLessonHistoryById(id);
                      },
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
          ),
        ),
      ),
    );
  }

  // ---------- 유틸 ----------
  String _safeDate(DateTime? d) =>
      d == null ? '-' : d.toIso8601String().split('T').first;

  String _safeSubject(Lesson l) {
    final s = l.subject;
    if (s == null) return '(제목 없음)';
    final t = s.trim();
    return t.isEmpty ? '(제목 없음)' : t;
  }
}

// ===== 내부 모델/위젯 =====

class _RecentStudent {
  final String studentId;
  final DateTime lastDate;
  const _RecentStudent({required this.studentId, required this.lastDate});
}

class _Recent14List extends StatelessWidget {
  final List<_RecentStudent> list;
  final Map<String, String> nameMap;
  final void Function(String studentId) onOpenHome;
  final void Function(String studentId) onOpenEdit;

  const _Recent14List({
    required this.list,
    required this.nameMap,
    required this.onOpenHome,
    required this.onOpenEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final row = list[i];
        final name = (nameMap[row.studentId] ?? '').trim();
        final display = name.isEmpty ? '학생ID: ${row.studentId}' : name;
        final dateStr = row.lastDate.toIso8601String().split('T').first;

        return ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(display, style: theme.textTheme.bodyLarge),
          subtitle: Text('최근 수업일: $dateStr'),
          trailing: Wrap(
            spacing: 6,
            children: [
              IconButton(
                tooltip: '학생 홈 화면',
                icon: const Icon(Icons.switch_account),
                onPressed: () => onOpenHome(row.studentId),
              ),
              IconButton(
                tooltip: '수정',
                icon: const Icon(Icons.edit),
                onPressed: () => onOpenEdit(row.studentId),
              ),
            ],
          ),
          onTap: () => onOpenHome(row.studentId),
        );
      },
    );
  }
}

// ===== 오늘 수업 없음 섹션(비스크롤) =====

class _NoTodaySection extends StatelessWidget {
  final List<String> todayIds;
  final Map<String, String> todayNames;

  final List<String> recentIds;
  final Map<String, String> recentNames;

  final void Function(String studentId) onOpenHome;
  final void Function(String studentId) onOpenHistory;

  const _NoTodaySection({
    required this.todayIds,
    required this.todayNames,
    required this.recentIds,
    required this.recentNames,
    required this.onOpenHome,
    required this.onOpenHistory,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium;

    Widget section(
      String title,
      List<String> ids,
      Map<String, String> nameMap,
    ) {
      if (ids.isEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('$title: 없음', style: theme.textTheme.bodyMedium),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: titleStyle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ids.map((id) {
              final name = (nameMap[id] ?? id).trim();
              return _StudentChip(
                name: name.isEmpty ? id : name,
                onOpenHome: () => onOpenHome(id),
                onOpenHistory: () => onOpenHistory(id),
              );
            }).toList(),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.inbox, size: 42),
                const SizedBox(height: 8),
                Text('오늘 등록된 수업이 없습니다.', style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
          const SizedBox(height: 20),
          section('오늘 진행 학생', todayIds, todayNames),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          section('최근 진행 학생(14일)', recentIds, recentNames),
        ],
      ),
    );
  }
}

class _StudentChip extends StatelessWidget {
  final String name;
  final VoidCallback onOpenHome;
  final VoidCallback onOpenHistory;

  const _StudentChip({
    required this.name,
    required this.onOpenHome,
    required this.onOpenHistory,
  });

  @override
  Widget build(BuildContext context) {
    return InputChip(
      label: Text(name),
      avatar: const Icon(Icons.person),
      onPressed: onOpenHome,
      deleteIcon: const Icon(Icons.history),
      onDeleted: onOpenHistory,
      tooltip: '탭: 학생 화면 / 히스토리 아이콘: 지난 수업',
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
