// lib/screens/manage/manage_teachers_screen.dart
// v1.37.0 | 강사 관리 화면 – (구)Auth 연동 완전 제거 + UI 정리
// - AppBar ⋯ 메뉴에서 "권한/링크 동기화" 완전 제거
// - 카드 팝업메뉴에서 "계정 링크 동기화" 완전 제거
// - 진단 다이얼로그에서 ensureTeacherLink() 호출 제거 (조회/권한 확인만)
// - 목록/등록/편집/삭제/비밀번호 변경(teachers.password_hash: SHA-256) 기능 유지
//
// 의존:
// - services: AuthService, TeacherService
// - models: Teacher
// - supabase: Supabase.instance.client.rpc('is_current_user_admin') 사용(선택)
// - pub: supabase_flutter

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/auth_service.dart';
import '../../services/teacher_service.dart';
import '../../models/teacher.dart';

class ManageTeachersScreen extends StatefulWidget {
  const ManageTeachersScreen({super.key});

  @override
  State<ManageTeachersScreen> createState() => _ManageTeachersScreenState();
}

class _ManageTeachersScreenState extends State<ManageTeachersScreen> {
  final _teacher = TeacherService();
  final _auth = AuthService();

  bool _loading = true;
  List<Teacher> _items = const [];

  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  Future<void> _load({bool initial = false}) async {
    if (initial) setState(() => _loading = true);
    try {
      final list = await _teacher.listBasic();
      if (!mounted) return;
      setState(() => _items = list);
    } catch (e) {
      _toast('목록 불러오기 실패: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _onTapRefresh() async {
    await _load();
    _toast('새로고침 완료');
  }

  Future<void> _onTapRegister() async {
    final res = await showDialog<_RegisterTeacherResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _RegisterTeacherDialog(),
    );
    if (res == null) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final ok = await _teacher.registerTeacher(
        name: res.name,
        email: res.email,
        password: res.password,
        isAdmin: res.isAdmin,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // progress 닫기
      if (ok) {
        _toast('강사 등록(초대) 완료');
        await _load();
      } else {
        _toast('강사 등록 실패(서버 응답 없음)');
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // progress 닫기
      final msg = e.toString();
      if (msg.contains('23505')) {
        _toast('이미 존재하는 계정/링크입니다. 이메일 중복 또는 기존 연결을 확인해 주세요.');
      } else {
        _toast('강사 등록 실패: $e');
      }
    }
  }

  Future<void> _copyText(String text, {String? toast}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (toast != null) _toast(toast);
  }

  Future<void> _editTeacher(Teacher t) async {
    final res = await showDialog<_EditTeacherResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EditTeacherDialog(teacher: t),
    );
    if (res == null) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await _teacher.updateBasic(id: t.id, name: res.name, email: res.email);
      if (res.isAdmin != t.isAdmin) {
        await _teacher.setAdmin(id: t.id, isAdmin: res.isAdmin);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      _toast('수정 완료');
      await _load();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      final msg = e.toString();
      if (msg.contains('23505')) {
        _toast('이메일이 다른 계정과 중복됩니다.');
      } else if (msg.contains('admin only')) {
        _toast('관리자 권한이 필요합니다.');
      } else {
        _toast('수정 실패: $e');
      }
    }
  }

  Future<void> _deleteTeacher(Teacher t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('강사 삭제'),
        content: Text('정말로 삭제할까요?\n${t.name} <${t.email}>'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_forever),
            label: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await _teacher.deleteTeacher(t.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      _toast('삭제되었습니다');
      await _load();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      final msg = e.toString();
      if (msg.contains('permission denied') || msg.contains('not allowed')) {
        _toast('관리자 권한이 필요합니다.');
      } else {
        _toast('삭제 실패: $e');
      }
    }
  }

  Future<void> _changePassword(Teacher t) async {
    final res = await showDialog<_ChangePasswordResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (res == null) return;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await _teacher.updatePasswordSha256ByEmail(
        email: t.email,
        newPassword: res.password,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      _toast('비밀번호 변경 완료 (앱 내부 해시 저장)');
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _toast('비밀번호 변경 실패: $e');
    }
  }

  Future<void> _diagnostics() async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final role = await _auth
          .getRole(); // student/teacher/admin 판별 (teachers 기준)
      bool isAdmin = false;
      try {
        final res =
            await Supabase.instance.client.rpc('is_current_user_admin')
                as bool?;
        isAdmin = res == true;
      } catch (_) {}

      final list = await _teacher.listBasic();

      if (!mounted) return;
      Navigator.of(context).pop();

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('권한/연결 진단'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('역할(Role): $role'),
              Text('관리자 여부: ${isAdmin ? "YES" : "NO"}'),
              Text('강사 수 조회: ${list.length}명'),
              const SizedBox(height: 8),
              const Text('※ 관리자·비밀번호는 Authentication에 의존하지 않습니다.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _toast('진단 실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('강사 관리'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _onTapRefresh,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'diagnostics':
                  _diagnostics();
                  break;
              }
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'diagnostics', child: Text('권한/연결 진단')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _onTapRegister,
        icon: const Icon(Icons.person_add),
        label: const Text('강사 등록'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? const _EmptyView()
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
                itemCount: _items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final t = _items[i];
                  final linked = (t.authUserId ?? '').isNotEmpty;
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        child: Icon(
                          linked ? Icons.verified_user : Icons.person_outline,
                        ),
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              t.name.isEmpty ? '(이름 없음)' : t.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (t.isAdmin)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Chip(
                                label: Text('ADMIN'),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                        ],
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.email),
                          if (t.lastLogin != null)
                            Text(
                              '최근 접속: ${t.lastLogin}',
                              style: const TextStyle(fontSize: 12),
                            ),
                        ],
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          switch (v) {
                            case 'copy_email':
                              _copyText(t.email, toast: '이메일을 복사했어요');
                              break;
                            case 'edit':
                              _editTeacher(t);
                              break;
                            case 'change_pw':
                              _changePassword(t);
                              break;
                            case 'delete':
                              _deleteTeacher(t);
                              break;
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'copy_email',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.copy),
                              title: Text('이메일 복사'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'edit',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.edit),
                              title: Text('편집'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'change_pw',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.lock),
                              title: Text('비밀번호 변경'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.delete_forever),
                              title: Text('삭제(관리자)'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.people_outline, size: 48),
            SizedBox(height: 12),
            Text(
              '등록된 강사가 없습니다.\n오른쪽 아래 버튼으로 강사를 등록해 주세요.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _RegisterTeacherDialog extends StatefulWidget {
  const _RegisterTeacherDialog();

  @override
  State<_RegisterTeacherDialog> createState() => _RegisterTeacherDialogState();
}

class _RegisterTeacherDialogState extends State<_RegisterTeacherDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtl = TextEditingController();
  final _emailCtl = TextEditingController();
  final _pwCtl = TextEditingController();
  bool _isAdmin = false;
  bool _submitting = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _emailCtl.dispose();
    _pwCtl.dispose();
    super.dispose();
  }

  String? _vEmail(String? v) {
    final s = (v ?? '').trim().toLowerCase();
    if (s.isEmpty) return '이메일을 입력해 주세요';
    if (!s.contains('@') || s.startsWith('@') || s.endsWith('@')) {
      return '이메일 형식이 올바르지 않습니다';
    }
    return null;
  }

  String? _vPw(String? v) {
    final s = (v ?? '').trim();
    if (s.length < 4) return '비밀번호는 4자리 이상이어야 합니다';
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _submitting = true);
    if (!mounted) return;
    Navigator.of(context).pop(
      _RegisterTeacherResult(
        name: _nameCtl.text.trim(),
        email: _emailCtl.text.trim().toLowerCase(),
        password: _pwCtl.text.trim(),
        isAdmin: _isAdmin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('강사 등록(초대)'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtl,
                decoration: const InputDecoration(
                  labelText: '이름',
                  hintText: '예) 홍길동',
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _emailCtl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: '이메일',
                  hintText: 'teacher@example.com',
                ),
                validator: _vEmail,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _pwCtl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '임시 비밀번호'),
                validator: _vPw,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Checkbox(
                    value: _isAdmin,
                    onChanged: (v) => setState(() => _isAdmin = v ?? false),
                  ),
                  const Text('관리자 권한'),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '※ 관리자 여부와 비밀번호는 Authentication과 무관하게 앱 내부에서만 관리합니다.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: const Icon(Icons.check),
          label: const Text('등록'),
        ),
      ],
    );
  }
}

class _RegisterTeacherResult {
  final String name;
  final String email;
  final String password;
  final bool isAdmin;

  _RegisterTeacherResult({
    required this.name,
    required this.email,
    required this.password,
    required this.isAdmin,
  });
}

// ================= 편집/비밀번호 다이얼로그 =================

class _EditTeacherDialog extends StatefulWidget {
  final Teacher teacher;
  const _EditTeacherDialog({required this.teacher});

  @override
  State<_EditTeacherDialog> createState() => _EditTeacherDialogState();
}

class _EditTeacherDialogState extends State<_EditTeacherDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtl;
  late TextEditingController _emailCtl;
  late bool _isAdmin;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.teacher.name);
    _emailCtl = TextEditingController(text: widget.teacher.email);
    _isAdmin = widget.teacher.isAdmin;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _emailCtl.dispose();
    super.dispose();
  }

  String? _vEmail(String? v) {
    final s = (v ?? '').trim().toLowerCase();
    if (s.isEmpty) return '이메일을 입력해 주세요';
    if (!s.contains('@') || s.startsWith('@') || s.endsWith('@')) {
      return '이메일 형식이 올바르지 않습니다';
    }
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!mounted) return;
    Navigator.of(context).pop(
      _EditTeacherResult(
        name: _nameCtl.text.trim(),
        email: _emailCtl.text.trim().toLowerCase(),
        isAdmin: _isAdmin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final linked = (widget.teacher.authUserId ?? '').isNotEmpty;
    return AlertDialog(
      title: const Text('강사 정보 수정'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtl,
                decoration: const InputDecoration(labelText: '이름'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _emailCtl,
                decoration: const InputDecoration(labelText: '이메일'),
                validator: _vEmail,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('관리자 권한'),
                value: _isAdmin,
                onChanged: (v) => setState(() => _isAdmin = v),
              ),
              const Divider(),
              ListTile(
                dense: true,
                title: const Text('연결된 Auth 사용자'),
                subtitle: Text(linked ? widget.teacher.authUserId! : '연결 없음'),
                trailing: linked
                    ? const Icon(Icons.verified_user)
                    : const Icon(Icons.link_off),
              ),
              if (widget.teacher.lastLogin != null)
                ListTile(
                  dense: true,
                  title: const Text('최근 접속'),
                  subtitle: Text(widget.teacher.lastLogin.toString()),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.save),
          label: const Text('저장'),
        ),
      ],
    );
  }
}

class _EditTeacherResult {
  final String name;
  final String email;
  final bool isAdmin;

  _EditTeacherResult({
    required this.name,
    required this.email,
    required this.isAdmin,
  });
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pwCtl = TextEditingController();
  final _pw2Ctl = TextEditingController();

  @override
  void dispose() {
    _pwCtl.dispose();
    _pw2Ctl.dispose();
    super.dispose();
  }

  String? _vPw(String? v) {
    final s = (v ?? '').trim();
    if (s.length < 4) return '비밀번호는 4자리 이상이어야 합니다';
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_pwCtl.text.trim() != _pw2Ctl.text.trim()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('비밀번호가 일치하지 않습니다')));
      return;
    }
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(_ChangePasswordResult(password: _pwCtl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('비밀번호 변경'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _pwCtl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '새 비밀번호'),
                validator: _vPw,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _pw2Ctl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '새 비밀번호 확인'),
                validator: _vPw,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.check),
          label: const Text('변경'),
        ),
      ],
    );
  }
}

class _ChangePasswordResult {
  final String password;
  _ChangePasswordResult({required this.password});
}
