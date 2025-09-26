// lib/screens/manage/manage_students_screen.dart
// v1.36.5 | 라우트 인자(focusStudentId, autoOpenEdit) 처리 추가
// - TeacherHomeBody 등에서 관리 화면으로 이동 시 즉시 해당 학생 수정 다이얼로그 열 수 있음.
// - 기존 목록/검색/CRUD 기능은 동일.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/auth_service.dart';
import '../../services/student_service.dart';
import '../../services/teacher_service.dart';
import '../../models/student.dart';
import '../../models/teacher.dart';
import '../../supabase/supabase_tables.dart';
import '../../routes/app_routes.dart';

String _asStr(Object? v) => v is String ? v : (v?.toString() ?? '');

class ManageStudentsScreen extends StatefulWidget {
  const ManageStudentsScreen({super.key});

  @override
  State<ManageStudentsScreen> createState() => _ManageStudentsScreenState();
}

class _ManageStudentsScreenState extends State<ManageStudentsScreen> {
  final _auth = AuthService();
  final _svc = StudentService();
  final _teacherSvc = TeacherService();
  final _sp = Supabase.instance.client;

  final _searchCtl = TextEditingController();
  Timer? _searchDebounce;
  static const _searchDebounceMs = 300;

  bool _loading = true;
  bool _guarding = true;
  bool _isAdmin = false;
  String? _error;

  int _loadSeq = 0; // 응답 경합 방지용 시퀀스

  List<Student> _list = const [];
  List<Teacher> _teachers = const [];
  Map<String, String> _teacherNameById = const {}; // id -> name

  final _dateFmt = DateFormat('yyyy-MM-dd');

  // 🔹 라우트 인자 처리용
  String? _routeFocusStudentId;
  bool _routeAutoOpenEdit = false;
  bool _routeArgsHandled = false;

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(_onSearchChanged);
    _guardAndLoad();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 최초 1회만 라우트 인자 파싱
    if (!_routeArgsHandled) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final fid = _asStr(args['focusStudentId']).trim();
        if (fid.isNotEmpty) _routeFocusStudentId = fid;
        _routeAutoOpenEdit = (args['autoOpenEdit'] == true);
      }
      // prefill은 검색창에 반영(선택)
      final prefill = (args is Map) ? _asStr(args['prefill']).trim() : '';
      if (prefill.isNotEmpty) {
        _searchCtl.text = prefill;
      }
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtl.removeListener(_onSearchChanged);
    _searchCtl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: _searchDebounceMs),
      () {
        if (mounted) _load();
      },
    );
  }

  Future<void> _guardAndLoad() async {
    try {
      final role = await _auth.getRole();
      _isAdmin = role == UserRole.admin;
    } catch (_) {
      _isAdmin = false;
    }
    if (!mounted) return;
    setState(() => _guarding = false);
    if (_isAdmin) {
      await _loadTeachers();
      await _load();
    }
  }

  Future<void> _loadTeachers() async {
    try {
      final list = await _teacherSvc.listBasic();
      if (!mounted) return;
      setState(() {
        _teachers = list;
        _teacherNameById = {
          for (final t in list)
            t.id: (t.name.trim().isEmpty ? t.email : t.name),
        };
      });
    } catch (_) {
      /* 교사 목록 실패 시에도 학생목록은 보이도록 무시 */
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final mySeq = ++_loadSeq;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final q = _searchCtl.text.trim();
      // ✅ 1) 서버 정렬: 이름 오름차순
      final data = await _svc.list(
        query: q,
        limit: 200,
        orderBy: 'name',
        ascending: true,
      );

      // ✅ 2) 클라이언트 보정 정렬(가나다/대소문자/공백 무시)
      final sorted = [...data]
        ..sort((a, b) {
          int c = _koreanKey(a.name).compareTo(_koreanKey(b.name));
          if (c != 0) return c;
          // 보조키: created_at (오래된 순)
          final atA = a.createdAt?.millisecondsSinceEpoch ?? 0;
          final atB = b.createdAt?.millisecondsSinceEpoch ?? 0;
          return atA.compareTo(atB);
        });

      if (!mounted || mySeq != _loadSeq) return; // 오래된 응답 무시
      setState(() => _list = sorted);

      // 🔹 리스트 로드 후, 필요 시 자동으로 해당 학생 수정 다이얼로그 열기
      _maybeFocusAndOpenEdit();
    } catch (e) {
      if (!mounted || mySeq != _loadSeq) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted && mySeq == _loadSeq) setState(() => _loading = false);
    }
  }

  void _maybeFocusAndOpenEdit() {
    if (_routeArgsHandled) return;
    if ((_routeFocusStudentId ?? '').isEmpty) return;
    final targetId = _routeFocusStudentId!;
    Student? target;
    for (final s in _list) {
      if (s.id == targetId) {
        target = s;
        break;
      }
    }
    if (target == null) return;

    _routeArgsHandled = true;

    if (_routeAutoOpenEdit) {
      // 프레임 이후 다이얼로그 오픈(빌드 충돌 방지)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onEdit(target!);
      });
    } else {
      // 필요 시 스크롤 포커싱 등을 여기에 추가 가능
    }
  }

  /// 한글/영문 정렬 키 생성: 공백 제거 + 소문자 변환
  String _koreanKey(String v) {
    final t = v.trim().toLowerCase();
    // 필요 시 추가 전처리: 특수문자 제거 등
    return t.replaceAll(RegExp(r'\s+'), '');
  }

  // ---- 오류 핸들링 유틸 ----
  bool _isPermError(Object e) {
    if (e is PostgrestException) {
      final msg = _asStr(e.message).toLowerCase();
      final hint = _asStr(e.hint).toLowerCase();
      final code = _asStr(e.code).toLowerCase();

      return code == '42501' ||
          msg.contains('permission denied') ||
          msg.contains('violates row-level security') ||
          hint.contains('policy') ||
          hint.contains('rls');
    }
    final s = e.toString().toLowerCase();
    return s.contains('permission') || s.contains('rls');
  }

  String _friendlyError(Object e) {
    if (e is PostgrestException) {
      final isPerm = _isPermError(e);
      if (isPerm) {
        return '권한이 없습니다. 관리자 계정과 RLS 정책을 확인하세요.';
      }
      return '작업 중 오류가 발생했습니다.\n${e.message}';
    }
    final s = e.toString().toLowerCase();
    if (s.contains('network') || s.contains('timeout')) {
      return '네트워크 오류가 발생했습니다. 연결 상태를 확인하고 다시 시도하세요.';
    }
    return '작업 중 오류가 발생했습니다.\n$e';
  }

  void _showError(String msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('오류'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _retryRepair() async {
    await _auth.ensureTeacherLink(); // auth_user_id ↔ teachers 매핑 보정
    await _load();
  }

  Future<void> _withBusy(Future<void> Function() task) async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      await task();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---- 학생 화면 진입 ----
  Future<void> _openAsStudent(Student s) async {
    await AppRoutes.pushStudentHome(
      context,
      studentId: s.id,
      studentName: s.name,
      adminDrive: true,
    );
  }

  // ---- CRUD ----
  Future<void> _onAdd() async {
    final r = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _EditStudentDialog(teachers: _teachers),
    );
    if (r == null) return;

    await _withBusy(() async {
      try {
        await _svc.create(
          name: r.name,
          phoneLast4: r.last4,
          teacherId: r.teacherId?.trim().isEmpty == true ? null : r.teacherId,
          gender: r.gender,
          isAdult: r.isAdult,
          schoolName: r.schoolName,
          grade: r.grade,
          startDate: r.startDate,
          instrument: r.instrument,
          memo: r.memo,
          isActive: r.isActive,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('학생이 등록되었습니다.')));
        await _load();
      } catch (e) {
        if (_isPermError(e)) {
          await _auth.ensureTeacherLink();
          try {
            await _svc.create(
              name: r.name,
              phoneLast4: r.last4,
              teacherId: r.teacherId?.trim().isNotEmpty == true
                  ? r.teacherId
                  : null,
              gender: r.gender,
              isAdult: r.isAdult,
              schoolName: r.schoolName,
              grade: r.grade,
              startDate: r.startDate,
              instrument: r.instrument,
              memo: r.memo,
              isActive: r.isActive,
            );
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('학생이 등록되었습니다. (링크 보정 후)')),
            );
            await _load();
            return;
          } catch (e2) {
            if (!mounted) return;
            _showError(_friendlyError(e2));
          }
        } else {
          if (!mounted) return;
          _showError(_friendlyError(e));
        }
      }
    });
  }

  Future<void> _onEdit(Student s) async {
    final r = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _EditStudentDialog(
        initialName: s.name,
        initialLast4: s.phoneLast4 ?? '',
        initialTeacherId: s.teacherId,
        initialGender: s.gender,
        initialIsAdult: s.isAdult,
        initialSchoolName: s.schoolName,
        initialGrade: s.grade,
        initialStartDate: s.startDate,
        initialInstrument: s.instrument,
        initialMemo: s.memo,
        initialIsActive: s.isActive,
        teachers: _teachers,
      ),
    );
    if (r == null) return;

    await _withBusy(() async {
      try {
        await _svc.update(
          id: s.id,
          name: r.name,
          phoneLast4: r.last4,
          teacherId: r.teacherId?.trim().isEmpty == true ? null : r.teacherId,
          gender: r.gender,
          isAdult: r.isAdult,
          schoolName: r.schoolName,
          grade: r.grade,
          startDate: r.startDate,
          instrument: r.instrument,
          memo: r.memo,
          isActive: r.isActive,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('학생 정보가 저장되었습니다.')));
        await _load();
      } catch (e) {
        if (_isPermError(e)) {
          await _auth.ensureTeacherLink();
          try {
            await _svc.update(
              id: s.id,
              name: r.name,
              phoneLast4: r.last4,
              teacherId: r.teacherId?.trim().isNotEmpty == true
                  ? r.teacherId
                  : null,
              gender: r.gender,
              isAdult: r.isAdult,
              schoolName: r.schoolName,
              grade: r.grade,
              startDate: r.startDate,
              instrument: r.instrument,
              memo: r.memo,
              isActive: r.isActive,
            );
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('학생 정보가 저장되었습니다. (링크 보정 후)')),
            );
            await _load();
            return;
          } catch (e2) {
            if (!mounted) return;
            _showError(_friendlyError(e2));
          }
        } else {
          if (!mounted) return;
          _showError(_friendlyError(e));
        }
      }
    });
  }

  Future<void> _onDelete(Student s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('학생 삭제'),
        content: Text('"${s.name}" 학생을 삭제할까요?\n연관 데이터가 있을 수 있습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _withBusy(() async {
      try {
        await _svc.remove(s.id);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('학생이 삭제되었습니다.')));
        await _load();
      } catch (e) {
        if (_isPermError(e)) {
          await _auth.ensureTeacherLink();
          try {
            await _svc.remove(s.id);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('학생이 삭제되었습니다. (링크 보정 후)')),
            );
            await _load();
            return;
          } catch (e2) {
            if (!mounted) return;
            _showError(_friendlyError(e2));
          }
        } else {
          if (!mounted) return;
          _showError(_friendlyError(e));
        }
      }
    });
  }

  // ---- 진단 도구 ----
  Future<void> _diagnose() async {
    final u = _sp.auth.currentUser;
    final email = (u?.email ?? '').trim().toLowerCase();
    final uid = u?.id ?? '(no auth)';

    String diag = '';

    // 1) 관리자 RPC
    bool? isAdminRpc;
    Object? isAdminErr;
    try {
      final res = await _sp.rpc('is_current_user_admin');
      isAdminRpc = (res is bool) ? res : null;
    } catch (e) {
      isAdminErr = e;
    }

    // 2) teachers row
    Map<String, dynamic>? teacherRow;
    Object? teacherErr;
    try {
      final List r = await _sp
          .from(SupabaseTables.teachers)
          .select('id, email, is_admin, auth_user_id')
          .eq('email', email)
          .limit(1);

      if (r.isNotEmpty) {
        teacherRow = Map<String, dynamic>.from(r.first as Map);
      }
    } catch (e) {
      teacherErr = e;
    }

    // 3) students SELECT
    Object? selectErr;
    try {
      await _sp.from(SupabaseTables.students).select('id').limit(1);
    } catch (e) {
      selectErr = e;
    }

    // 4) 임시 INSERT → DELETE (RLS/권한 실측)
    String? tmpId;
    Object? insertErr;
    Object? deleteErr;
    try {
      final tmpName = '__diag_${DateTime.now().millisecondsSinceEpoch}';
      final Map ins =
          await _sp
                  .from(SupabaseTables.students)
                  .insert({'name': tmpName})
                  .select('id')
                  .single()
              as Map;
      tmpId = ins['id'] is String ? ins['id'] as String : null;
    } catch (e) {
      insertErr = e;
    }
    if (tmpId != null) {
      try {
        await _sp.from(SupabaseTables.students).delete().eq('id', tmpId);
      } catch (e) {
        deleteErr = e;
      }
    }

    diag += 'Auth Email: $email\n';
    diag += 'Auth UID:   $uid\n\n';
    diag += 'RPC is_admin: ${isAdminRpc ?? '(fail)'}\n';
    if (isAdminErr != null) diag += '  RPC error: $isAdminErr\n';
    diag += 'Teacher Row: ${teacherRow ?? '(not found / error)'}\n';
    if (teacherErr != null) diag += '  Teacher error: $teacherErr\n';
    diag += '\nSELECT students: ${selectErr == null ? 'OK' : 'ERROR'}\n';
    if (selectErr != null) diag += '  $selectErr\n';
    diag += 'INSERT temp: ${insertErr == null ? 'OK' : 'ERROR'}\n';
    if (insertErr != null) diag += '  $insertErr\n';
    diag +=
        'DELETE temp: ${deleteErr == null ? (tmpId == null ? 'SKIP' : 'OK') : 'ERROR'}\n';
    if (deleteErr != null) diag += '  $deleteErr\n';

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('권한/연결 진단'),
        content: SingleChildScrollView(
          child: SelectableText(
            diag,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Future<void> _syncLinkNow() async {
    await _auth.ensureTeacherLink();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('권한 링크를 동기화했습니다.')));
  }

  @override
  Widget build(BuildContext context) {
    if (_guarding) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('학생 관리')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 42),
                const SizedBox(height: 8),
                const Text('관리자 전용 화면입니다.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('뒤로'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('학생 관리'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          PopupMenuButton<String>(
            tooltip: '도구',
            onSelected: (v) async {
              switch (v) {
                case 'diag':
                  await _diagnose();
                  break;
                case 'link':
                  await _syncLinkNow();
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'diag', child: Text('권한/연결 진단')),
              PopupMenuItem(value: 'link', child: Text('권한 링크 동기화')),
            ],
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : _onAdd,
        tooltip: '학생 추가',
        child: const Icon(Icons.person_add),
      ),
      body: Column(
        children: [
          // 검색 바
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(), // 엔터 검색도 그대로 지원
              decoration: InputDecoration(
                hintText: '이름으로 검색 (입력 시 자동 검색)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  onPressed: () {
                    _searchCtl.clear();
                    FocusScope.of(context).unfocus();
                    _load(); // 즉시 재조회
                  },
                  icon: const Icon(Icons.clear),
                  tooltip: '초기화',
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _ErrorView(message: _error!, onRetry: _retryRepair)
                : _list.isEmpty
                ? _EmptyView(onRetry: _load)
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final s = _list[i];
                      final teacherName =
                          (s.teacherId != null &&
                              s.teacherId!.trim().isNotEmpty)
                          ? (_teacherNameById[s.teacherId!] ?? '미배정')
                          : '미배정';
                      final last4 = s.phoneLast4?.trim() ?? '';
                      final start = s.startDate == null
                          ? null
                          : _dateFmt.format(s.startDate!.toLocal());
                      final info = <String>[
                        if (last4.isNotEmpty) '전화: ****-$last4',
                        '강사: $teacherName',
                        s.isAdult ? '성인' : '학생',
                        if ((s.instrument ?? '').isNotEmpty)
                          '악기: ${s.instrument}',
                        if ((s.schoolName ?? '').isNotEmpty)
                          '학교: ${s.schoolName}${s.grade == null ? '' : ' ${s.grade}학년'}',
                        if (start != null) '시작일: $start',
                        s.isActive ? '활성' : '비활성',
                        if (s.createdAt != null)
                          '등록: ${_dateFmt.format(s.createdAt!.toLocal())}',
                      ].join(' · ');
                      return ListTile(
                        leading: Icon(
                          s.isActive ? Icons.person : Icons.person_off,
                        ),
                        title: Text(s.name),
                        subtitle: Text(info),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            // 학생 화면 열기
                            IconButton(
                              tooltip: '학생 화면',
                              icon: const Icon(Icons.switch_account),
                              onPressed: _loading
                                  ? null
                                  : () => _openAsStudent(s),
                            ),
                            IconButton(
                              tooltip: '수정',
                              icon: const Icon(Icons.edit),
                              onPressed: _loading ? null : () => _onEdit(s),
                            ),
                            IconButton(
                              tooltip: '삭제',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _loading ? null : () => _onDelete(s),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
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
            const Text('등록된 학생이 없습니다.'),
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

// ---------- 학생 추가/수정 다이얼로그 ----------
class _EditResult {
  final String name;
  final String last4;
  final String? teacherId;
  final String? gender; // '남' | '여'
  final bool isAdult;
  final String? schoolName;
  final int? grade;
  final DateTime? startDate; // date-only
  final String? instrument; // '통기타' | '일렉기타' | '클래식기타'
  final String? memo;
  final bool isActive;

  const _EditResult({
    required this.name,
    required this.last4,
    required this.teacherId,
    required this.gender,
    required this.isAdult,
    required this.schoolName,
    required this.grade,
    required this.startDate,
    required this.instrument,
    required this.memo,
    required this.isActive,
  });
}

class _EditStudentDialog extends StatefulWidget {
  final String? initialName;
  final String? initialLast4;
  final String? initialTeacherId;

  final String? initialGender;
  final bool? initialIsAdult;
  final String? initialSchoolName;
  final int? initialGrade;
  final DateTime? initialStartDate;
  final String? initialInstrument;
  final String? initialMemo;
  final bool? initialIsActive;

  final List<Teacher> teachers;

  const _EditStudentDialog({
    this.initialName,
    this.initialLast4,
    this.initialTeacherId,
    this.initialGender,
    this.initialIsAdult,
    this.initialSchoolName,
    this.initialGrade,
    this.initialStartDate,
    this.initialInstrument,
    this.initialMemo,
    this.initialIsActive,
    required this.teachers,
  });

  @override
  State<_EditStudentDialog> createState() => _EditStudentDialogState();
}

class _EditStudentDialogState extends State<_EditStudentDialog> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _last4Ctl;
  late final TextEditingController _schoolCtl;
  late final TextEditingController _gradeCtl;
  late final TextEditingController _memoCtl;

  String? _selectedTeacherId;
  String? _gender; // '남' | '여' | null
  bool _isAdult = true;
  String? _instrument; // '통기타' | '일렉기타' | '클래식기타' | null
  DateTime? _startDate; // date-only
  bool _isActive = true;

  final _dateFmt = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.initialName ?? '');
    _last4Ctl = TextEditingController(text: widget.initialLast4 ?? '');
    _schoolCtl = TextEditingController(text: widget.initialSchoolName ?? '');
    _gradeCtl = TextEditingController(
      text: widget.initialGrade?.toString() ?? '',
    );
    _memoCtl = TextEditingController(text: widget.initialMemo ?? '');
    _selectedTeacherId = widget.initialTeacherId;
    _gender = widget.initialGender;
    _isAdult = widget.initialIsAdult ?? true;
    _instrument = widget.initialInstrument;
    _startDate = widget.initialStartDate;
    _isActive = widget.initialIsActive ?? true;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _last4Ctl.dispose();
    _schoolCtl.dispose();
    _gradeCtl.dispose();
    _memoCtl.dispose();
    super.dispose();
  }

  bool _isValidLast4(String v) {
    if (v.trim().isEmpty) return true; // 빈값 허용(선택 입력)
    return RegExp(r'^[0-9]{4}$').hasMatch(v.trim());
  }

  int? _parseGrade(String v) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final init = _startDate ?? DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime(now.year + 2, 12, 31),
    );
    if (picked != null) {
      setState(
        () => _startDate = DateTime(picked.year, picked.month, picked.day),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = (widget.initialName ?? '').isNotEmpty;

    return AlertDialog(
      title: Text(isEdit ? '학생 정보 수정' : '학생 추가'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 이름
              TextField(
                controller: _nameCtl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '이름 *',
                  hintText: '예: 홍길동',
                ),
              ),
              const SizedBox(height: 12),

              // 전화 뒷자리
              TextField(
                controller: _last4Ctl,
                maxLength: 4,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '전화 뒷자리 4',
                  hintText: '예: 1234',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),

              // 담당 강사
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '담당 강사(선택)',
                  border: OutlineInputBorder(),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    isExpanded: true,
                    value: _selectedTeacherId?.isEmpty == true
                        ? null
                        : _selectedTeacherId,
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem(value: null, child: Text('미배정')),
                      ...widget.teachers.map((t) {
                        final label = t.name.trim().isEmpty ? t.email : t.name;
                        return DropdownMenuItem(
                          value: t.id,
                          child: Text(label),
                        );
                      }),
                    ],
                    onChanged: (v) => setState(() => _selectedTeacherId = v),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 성별 + 성인여부
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: '성별(선택)',
                        border: OutlineInputBorder(),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          value: _gender,
                          items: const [
                            DropdownMenuItem(value: null, child: Text('미지정')),
                            DropdownMenuItem(value: '남', child: Text('남')),
                            DropdownMenuItem(value: '여', child: Text('여')),
                          ],
                          onChanged: (v) => setState(() => _gender = v),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      title: const Text('성인'),
                      value: _isAdult,
                      onChanged: (v) => setState(() => _isAdult = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 학교/학년
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _schoolCtl,
                      decoration: const InputDecoration(
                        labelText: '학교(선택)',
                        hintText: '예: 한빛고, 샛별초, 희망중',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _gradeCtl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '학년(선택)',
                        hintText: '예: 2',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 시작일 + 악기
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: '시작일(선택)',
                        border: OutlineInputBorder(),
                      ),
                      child: InkWell(
                        onTap: _pickDate,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            children: [
                              const Icon(Icons.event, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                _startDate == null
                                    ? '미지정'
                                    : _dateFmt.format(_startDate!.toLocal()),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: '악기(선택)',
                        border: OutlineInputBorder(),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          value: _instrument,
                          items: const [
                            DropdownMenuItem(value: null, child: Text('미지정')),
                            DropdownMenuItem(value: '통기타', child: Text('통기타')),
                            DropdownMenuItem(
                              value: '일렉기타',
                              child: Text('일렉기타'),
                            ),
                            DropdownMenuItem(
                              value: '클래식기타',
                              child: Text('클래식기타'),
                            ),
                          ],
                          onChanged: (v) => setState(() => _instrument = v),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 활성/비활성
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('활성(수업 대상)'),
                subtitle: const Text('비활성으로 두면 검색/배정에서 제외(정산/기록은 유지)'),
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v),
              ),
              const SizedBox(height: 8),

              // 메모
              TextField(
                controller: _memoCtl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '메모(선택)',
                  hintText: '특이사항, 곡 취향, 수업 메모 등',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameCtl.text.trim();
            final l4 = _last4Ctl.text.trim();
            if (name.isEmpty) return;
            if (!_isValidLast4(l4)) return;

            final result = _EditResult(
              name: name,
              last4: l4,
              teacherId: _selectedTeacherId,
              gender: _gender,
              isAdult: _isAdult,
              schoolName: _schoolCtl.text.trim().isEmpty
                  ? null
                  : _schoolCtl.text.trim(),
              grade: _parseGrade(_gradeCtl.text),
              startDate: _startDate,
              instrument: _instrument,
              memo: _memoCtl.text.trim().isEmpty ? null : _memoCtl.text.trim(),
              isActive: _isActive,
            );
            Navigator.pop(context, result);
          },
          child: Text(isEdit ? '저장' : '추가'),
        ),
      ],
    );
  }
}
