// v1.33.10 - '학생 홈 화면', '수정' 버튼 동작을 학생 관리 화면과 동일하게 정렬
//            - 학생 홈 화면: AppRoutes.pushStudentHome(..., adminDrive: true)
//            - 수정: ManageStudentsScreen로 이동하며 focusStudentId + autoOpenEdit 전달

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/auth_service.dart';
import '../../../services/student_service.dart';
import '../../../routes/app_routes.dart';

class TeacherHomeBody extends StatefulWidget {
  const TeacherHomeBody({super.key});

  @override
  State<TeacherHomeBody> createState() => _TeacherHomeBodyState();
}

class _TeacherHomeBodyState extends State<TeacherHomeBody> {
  final _studentSvc = StudentService();
  final _sp = Supabase.instance.client;

  // ✅ 오늘 진행 학생 (최근 로직 재사용)
  List<_RecentStudent> _todayUnique = const [];
  Map<String, String> _todayNames = const {};

  // 오늘자 학생 ID 목록(최근/오늘 섹션간 중복제거 용)
  List<String> _todayStudentIds = const [];

  // 최근 14일 유니크
  List<_RecentStudent> _recent14Unique = const [];
  Map<String, String> _recent14Names = const {};

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _guardAndLoad();
  }

  Future<void> _guardAndLoad() async {
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
          _todayUnique = const [];
          _todayNames = const {};
          _todayStudentIds = const [];
          _recent14Unique = const [];
          _recent14Names = const {};
          _error = '세션이 만료되었거나 사용자 정보가 없습니다.';
        });
        return;
      }

      final teacherId = await _resolveMyTeacherId(
        authUid: user.id,
        email: user.email ?? '',
      );

      if (teacherId == null) {
        setState(() {
          _todayUnique = const [];
          _todayNames = const {};
          _todayStudentIds = const [];
          _recent14Unique = const [];
          _recent14Names = const {};
          _error = '교사 계정이 teachers 테이블과 연결되어 있지 않습니다.';
        });
        return;
      }

      // 최근 14일(오늘 포함) 유니크 50
      final recent14 = await _fetchRecentStudentsWithLastDateByMyStudents(
        myStudentIds: await _fetchMyStudentIds(teacherId),
        days: 14,
        limit: 50,
      );
      final ids14 = recent14.map((e) => e.studentId).toList();
      final nameMap14 = ids14.isEmpty
          ? <String, String>{}
          : await _studentSvc.fetchNamesByIds(ids14);

      // ✅ 오늘 진행 학생: 최근 리스트에서 lastDate == 오늘 인 것만 필터
      final now = DateTime.now();
      final todayOnly = DateTime(now.year, now.month, now.day);
      final todayFromRecent = recent14.where((e) {
        final d = DateTime(e.lastDate.year, e.lastDate.month, e.lastDate.day);
        return _isSameDate(d, todayOnly);
      }).toList();

      final todayIds = todayFromRecent.map((e) => e.studentId).toList();
      final nameMapTodayFromRecent = todayIds.isEmpty
          ? <String, String>{}
          : await _studentSvc.fetchNamesByIds(todayIds);

      if (!mounted) return;
      setState(() {
        // 화면 표시용(최근 구조 기반)
        _todayUnique = todayFromRecent;
        _todayNames = nameMapTodayFromRecent;
        _todayStudentIds = todayIds;

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

  Future<String?> _resolveMyTeacherId({
    required String authUid,
    required String email,
  }) async {
    final List byUid = await _sp
        .from('teachers')
        .select('id')
        .eq('auth_user_id', authUid)
        .limit(1);
    if (byUid.isNotEmpty) {
      final m = Map<String, dynamic>.from(byUid.first as Map);
      final id = (m['id'] ?? '').toString();
      if (id.isNotEmpty) return id;
    }
    final e = email.trim().toLowerCase();
    if (e.isEmpty) return null;
    final List byEmail = await _sp
        .from('teachers')
        .select('id')
        .eq('email', e)
        .limit(1);
    if (byEmail.isNotEmpty) {
      final m = Map<String, dynamic>.from(byEmail.first as Map);
      final id = (m['id'] ?? '').toString();
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  Future<Set<String>> _fetchMyStudentIds(String teacherId) async {
    final List rows = await _sp
        .from('students')
        .select('id')
        .eq('teacher_id', teacherId);
    return rows
        .map((r) => (r as Map)['id']?.toString())
        .where((id) => id != null && id.isNotEmpty)
        .cast<String>()
        .toSet();
  }

  Future<List<_RecentStudent>> _fetchRecentStudentsWithLastDateByMyStudents({
    required Set<String> myStudentIds,
    int days = 14,
    int limit = 50,
  }) async {
    if (myStudentIds.isEmpty) return const [];
    final now = DateTime.now();
    final from = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: days));
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
      final d = DateTime.tryParse((m['date'] ?? '').toString());
      if (d == null) continue;
      if (lastByStudent[sid] == null || d.isAfter(lastByStudent[sid]!)) {
        lastByStudent[sid] = d;
      }
    }

    final sorted = lastByStudent.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sorted
        .take(limit)
        .map((e) => _RecentStudent(studentId: e.key, lastDate: e.value))
        .toList();
  }

  String _dateOnly(DateTime d) =>
      DateTime(d.year, d.month, d.day).toIso8601String().split('T').first;

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _load);
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTodaySection(), // ✅ 오늘 진행 학생(최근 구조)
              _buildRecent14Section(), // ← 오늘자는 제외된 상태로 렌더
            ],
          ),
        ),
      ),
    );
  }

  // ✅ 오늘 진행 학생 섹션: 최근 구조 재사용
  Widget _buildTodaySection() {
    final list = _todayUnique;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
          child: Text(
            '오늘 진행 학생${list.isEmpty ? '' : ' (${list.length}명)'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('오늘 진행할 학생이 없습니다.'),
          )
        else
          _Recent14List(
            list: list,
            nameMap: _todayNames,
            onOpenHome: _openStudentHomeByIdAdminDrive,
            onOpenEdit: _openStudentEdit,
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildRecent14Section() {
    // ✅ 오늘자 학생은 '최근 진행 학생'에서 제외 (날짜 또는 ID 기준 모두)
    final now = DateTime.now();
    final todayOnly = DateTime(now.year, now.month, now.day);

    final filtered = _recent14Unique.where((e) {
      final d = DateTime(e.lastDate.year, e.lastDate.month, e.lastDate.day);
      final isToday = _isSameDate(d, todayOnly);
      final isInTodayIds = _todayStudentIds.contains(e.studentId);
      return !isToday && !isInTodayIds;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '최근 진행 학생',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('최근 진행한 학생이 없습니다.'),
          )
        else
          _Recent14List(
            list: filtered,
            nameMap: _recent14Names,
            onOpenHome: _openStudentHomeByIdAdminDrive,
            onOpenEdit: _openStudentEdit,
          ),
      ],
    );
  }

  // ✅ 학생 홈 화면 — 관리자/교사용 진입 (ManageStudents와 동일한 경로)
  Future<void> _openStudentHomeByIdAdminDrive(
    String studentId, {
    String? name,
  }) async {
    if (!mounted) return;
    await AppRoutes.pushStudentHome(
      context,
      studentId: studentId,
      studentName: (name ?? '').trim().isEmpty ? null : name!.trim(),
      adminDrive: true, // 중요: 학생 관리 화면의 '학생 화면'과 동일
    );
  }

  // ✅ 수정 — 학생 관리 화면으로 이동하면서 자동 편집 다이얼로그 오픈
  Future<void> _openStudentEdit(String studentId, {String? name}) async {
    if (!mounted) return;
    Navigator.pushNamed(
      context,
      AppRoutes.manageStudents,
      arguments: {
        'focusStudentId': studentId,
        'prefill': (name ?? '').trim(),
        'autoOpenEdit': true, // 중요: 진입 후 자동으로 수정 다이얼로그 열기
      },
    );
  }
}

class _RecentStudent {
  final String studentId;
  final DateTime lastDate;
  const _RecentStudent({required this.studentId, required this.lastDate});
}

class _Recent14List extends StatelessWidget {
  final List<_RecentStudent> list;
  final Map<String, String> nameMap;
  final void Function(String) onOpenHome;
  final void Function(String) onOpenEdit;

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
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final row = list[i];
        final name = (nameMap[row.studentId] ?? '').trim();
        return ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(
            name.isEmpty ? row.studentId : name,
            style: theme.textTheme.bodyLarge,
          ),
          subtitle: Text(
            '최근 수업일: ${row.lastDate.toIso8601String().split('T').first}',
          ),
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
