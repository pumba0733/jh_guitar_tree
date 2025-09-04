// lib/screens/manage/manage_students_screen.dart
// v1.35.4 | 학생 관리(관리자 전용)
// 변경점 요약
// 1) CRUD 전체 try/catch + 스낵바/다이얼로그 피드백 확실화
// 2) 권한 오류 추정 시 ensureTeacherLink() 수행 후 1회 자동 재시도
// 3) AppBar에 ⋯(더보기) 진단 메뉴 추가:
//    - "권한/연결 진단" : 현재 로그인/관리자 여부/RLS로 인한 오류/임시 INSERT→DELETE까지 점검
//    - "권한 링크 동기화" : teachers.auth_user_id 매핑 즉시 동기화
// 4) _onEdit에서 teacherId 빈문자→null 정규화 (UPDATE 무반응 방지)
// 5) phoneLast4 null 안전 표시

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/auth_service.dart';
import '../../services/student_service.dart';
import '../../services/teacher_service.dart';
import '../../models/student.dart';
import '../../models/teacher.dart';
import '../../supabase/supabase_tables.dart';

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
  bool _loading = true;
  bool _guarding = true;
  bool _isAdmin = false;
  String? _error;

  List<Student> _list = const [];
  List<Teacher> _teachers = const [];
  Map<String, String> _teacherNameById = const {}; // id -> name

  @override
  void initState() {
    super.initState();
    _guardAndLoad();
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
      setState(() {
        _teachers = list;
        _teacherNameById = {
          for (final t in list)
            t.id: (t.name.trim().isEmpty ? t.email : t.name),
        };
      });
    } catch (_) {
      // 교사 목록 실패 시에도 학생목록은 보이도록 무시
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final q = _searchCtl.text.trim();
      final data = await _svc.list(
        query: q,
        limit: 200,
        orderBy: 'created_at',
        ascending: false,
      );
      setState(() => _list = data);
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---- 오류 핸들링 유틸 ----
  bool _isPermError(Object e) {
    if (e is PostgrestException) {
      final msg = (e.message ?? '').toLowerCase();
      final hint = (e.hint ?? '').toLowerCase();
      final code = (e.code ?? '').toLowerCase();
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
      final msg = (e.message ?? '').toLowerCase();
      final hint = (e.hint ?? '').toLowerCase();
      final isPerm = _isPermError(e);
      if (isPerm) {
        return '권한이 없습니다. 관리자 계정과 RLS 정책을 확인하세요.';
      }
      return '작업 중 오류가 발생했습니다.\n${e.message ?? e.toString()}';
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
        );
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
              teacherId: r.teacherId?.trim().isEmpty == true
                  ? null
                  : r.teacherId,
            );
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('학생이 등록되었습니다. (링크 보정 후)')),
            );
            await _load();
            return;
          } catch (e2) {
            _showError(_friendlyError(e2));
          }
        } else {
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
          teacherId: r.teacherId?.trim().isEmpty == true
              ? null
              : r.teacherId, // ✅
        );
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
              teacherId: r.teacherId?.trim().isEmpty == true
                  ? null
                  : r.teacherId,
            );
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('학생 정보가 저장되었습니다. (링크 보정 후)')),
            );
            await _load();
            return;
          } catch (e2) {
            _showError(_friendlyError(e2));
          }
        } else {
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('학생이 삭제되었습니다.')));
        await _load();
      } catch (e) {
        if (_isPermError(e)) {
          await _auth.ensureTeacherLink();
          try {
            await _svc.remove(s.id);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('학생이 삭제되었습니다. (링크 보정 후)')),
            );
            await _load();
            return;
          } catch (e2) {
            _showError(_friendlyError(e2));
          }
        } else {
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
      final r = await _sp
          .from(SupabaseTables.teachers)
          .select('id, email, is_admin, auth_user_id')
          .eq('email', email)
          .limit(1);
      if (r is List && r.isNotEmpty) {
        teacherRow = Map<String, dynamic>.from(r.first);
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
      final ins = await _sp
          .from(SupabaseTables.students)
          .insert({'name': tmpName})
          .select('id')
          .single();
      tmpId = (ins is Map && ins['id'] is String) ? ins['id'] as String : null;
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
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: '이름으로 검색',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  onPressed: () {
                    _searchCtl.clear();
                    FocusScope.of(context).unfocus();
                    _load();
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
                // ⬇ 에러 시, 링크 보정 + 재시도
                ? _ErrorView(message: _error!, onRetry: _retryRepair)
                : _list.isEmpty
                ? _EmptyView(onRetry: _load)
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final s = _list[i];
                      final teacherName =
                          (s.teacherId != null &&
                              (s.teacherId ?? '').trim().isNotEmpty)
                          ? (_teacherNameById[s.teacherId!] ?? '미배정')
                          : '미배정';
                      final last4 = s.phoneLast4?.trim() ?? '';
                      return ListTile(
                        leading: const Icon(Icons.person),
                        title: Text(s.name),
                        subtitle: Text(
                          [
                            if (last4.isNotEmpty) '전화 뒷자리: $last4',
                            '담당강사: $teacherName',
                            if (s.createdAt != null)
                              '등록: ${s.createdAt!.toIso8601String().split("T").first}',
                          ].join(' · '),
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
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
  const _EditResult(this.name, this.last4, this.teacherId);
}

class _EditStudentDialog extends StatefulWidget {
  final String? initialName;
  final String? initialLast4;
  final String? initialTeacherId;
  final List<Teacher> teachers;

  const _EditStudentDialog({
    this.initialName,
    this.initialLast4,
    this.initialTeacherId,
    required this.teachers,
  });

  @override
  State<_EditStudentDialog> createState() => _EditStudentDialogState();
}

class _EditStudentDialogState extends State<_EditStudentDialog> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _last4Ctl;
  String? _selectedTeacherId;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.initialName ?? '');
    _last4Ctl = TextEditingController(text: widget.initialLast4 ?? '');
    _selectedTeacherId = widget.initialTeacherId;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _last4Ctl.dispose();
    super.dispose();
  }

  bool _isValidLast4(String v) {
    if (v.trim().isEmpty) return true; // 빈값 허용(선택 입력)
    return RegExp(r'^[0-9]{4}$').hasMatch(v.trim());
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = (widget.initialName ?? '').isNotEmpty;

    return AlertDialog(
      title: Text(isEdit ? '학생 정보 수정' : '학생 추가'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '이름',
                hintText: '예: 홍길동',
              ),
            ),
            const SizedBox(height: 12),
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
            const SizedBox(height: 16),
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
                      return DropdownMenuItem(value: t.id, child: Text(label));
                    }),
                  ],
                  onChanged: (v) => setState(() => _selectedTeacherId = v),
                ),
              ),
            ),
          ],
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
            Navigator.pop(context, _EditResult(name, l4, _selectedTeacherId));
          },
          child: Text(isEdit ? '저장' : '추가'),
        ),
      ],
    );
  }
}
