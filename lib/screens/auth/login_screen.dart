// lib/screens/auth/login_screen.dart
// v1.77.0 | 관리자 탭 제거 + 강사/관리자 라우팅 통합 (테이블 인증 전용)
// - 탭: 학생 / 강사 2개만 노출 (관리자 제거)
// - 강사 로그인 성공 후: AuthService.getRole()으로 admin이면 관리자 홈, 아니면 강사 홈 라우팅
// - 비밀번호 4자 이상 검증 유지
// - Supabase Auth 미사용(서비스 쪽에서 제거됨)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

enum LoginRole { student, teacher }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _prefsKeyRole = 'login.last_role';
  LoginRole _role = LoginRole.student;

  final _studentFormKey = GlobalKey<FormState>();
  final _emailFormKey = GlobalKey<FormState>();

  final _studentNameCtrl = TextEditingController();
  final _studentLast4Ctrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  final _studentNameFocus = FocusNode();
  final _studentLast4Focus = FocusNode();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();

  bool _loading = false;
  String? _error;
  bool _obscurePw = true;

  @override
  void initState() {
    super.initState();
    _restoreLastRole();
  }

  Future<void> _restoreLastRole() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt(_prefsKeyRole);
      if (idx != null && idx >= 0 && idx < LoginRole.values.length) {
        setState(() => _role = LoginRole.values[idx]);
      }
    } catch (_) {}
  }

  Future<void> _persistRole(LoginRole r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKeyRole, r.index);
    } catch (_) {}
  }

  void _setRole(LoginRole r) {
    setState(() {
      _role = r;
      _error = null;
    });
    _persistRole(r);
  }

  String? _validateStudentName(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return '학생 이름을 입력해 주세요';
    if (s.length > 20) return '이름은 20자 이내여야 합니다';
    return null;
  }

  String? _validateLast4(String? v) {
    final s = v?.trim() ?? '';
    if (s.length != 4) return '전화번호 뒤 4자리를 정확히 입력해 주세요';
    if (!RegExp(r'^\d{4}$').hasMatch(s)) return '숫자 4자리만 입력해 주세요';
    return null;
  }

  String? _validateEmail(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return '이메일을 입력해 주세요';
    final ok = RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(s);
    if (!ok) return '올바른 이메일 형식이 아닙니다';
    return null;
  }

  // ✅ 요구사항: 비밀번호 4자 이상
  String? _validatePassword(String? v) {
    final s = v ?? '';
    if (s.length < 4) return '비밀번호는 4자 이상이어야 합니다';
    return null;
  }

  Future<void> _submit() async {
    // 현재 역할에 맞는 폼 검증
    if (_role == LoginRole.student) {
      if (!(_studentFormKey.currentState?.validate() ?? false)) return;
    } else {
      if (!(_emailFormKey.currentState?.validate() ?? false)) return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final auth = AuthService();

      if (_role == LoginRole.student) {
        final ok = await auth.signInStudent(
          name: _studentNameCtrl.text.trim(),
          last4: _studentLast4Ctrl.text.trim(),
        );
        if (!ok) throw Exception('학생을 찾을 수 없습니다.');
        if (!mounted) return;
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil(AppRoutes.studentHome, (_) => false);
        return;
      }

      // 강사(관리자 포함) 로그인: 테이블 인증만 사용
      final ok = await auth.signInTeacherAdmin(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
      if (!ok) throw Exception('이메일 또는 비밀번호가 올바르지 않습니다.');

      final role = await auth.getRole(); // 테이블의 is_admin 기준
      final route = switch (role) {
        UserRole.admin => AppRoutes.adminHome,
        UserRole.teacher => AppRoutes.teacherHome,
        _ => AppRoutes.teacherHome,
      };

      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _studentNameCtrl.dispose();
    _studentLast4Ctrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _studentNameFocus.dispose();
    _studentLast4Focus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isStudent = _role == LoginRole.student;

    final roleTabs = ToggleButtons(
      isSelected: [_role == LoginRole.student, _role == LoginRole.teacher],
      onPressed: _loading ? null : (i) => _setRole(LoginRole.values[i]),
      children: const [
        Padding(padding: EdgeInsets.all(8), child: Text('학생')),
        Padding(padding: EdgeInsets.all(8), child: Text('강사')),
      ],
    );

    final studentForm = Form(
      key: _studentFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _studentNameCtrl,
            focusNode: _studentNameFocus,
            enabled: !_loading,
            decoration: const InputDecoration(labelText: '학생 이름'),
            textInputAction: TextInputAction.next,
            inputFormatters: [LengthLimitingTextInputFormatter(20)],
            validator: _validateStudentName,
            onFieldSubmitted: (_) => _studentLast4Focus.requestFocus(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _studentLast4Ctrl,
            focusNode: _studentLast4Focus,
            enabled: !_loading,
            decoration: const InputDecoration(labelText: '전화번호 뒤 4자리'),
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            validator: _validateLast4,
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _loading ? null : _submit,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(),
                  )
                : const Text('학생 로그인'),
          ),
        ],
      ),
    );

    final emailForm = Form(
      key: _emailFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _emailCtrl,
            focusNode: _emailFocus,
            enabled: !_loading,
            decoration: const InputDecoration(labelText: '이메일'),
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            validator: _validateEmail,
            onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _passwordCtrl,
            focusNode: _passwordFocus,
            enabled: !_loading,
            decoration: InputDecoration(
              labelText: '비밀번호',
              suffixIcon: IconButton(
                tooltip: _obscurePw ? '표시' : '숨김',
                icon: Icon(
                  _obscurePw ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: _loading
                    ? null
                    : () => setState(() => _obscurePw = !_obscurePw),
              ),
            ),
            obscureText: _obscurePw,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            validator: _validatePassword,
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _loading ? null : _submit,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(),
                  )
                : const Text('강사 로그인'),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('로그인')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  roleTabs,
                  const SizedBox(height: 20),
                  isStudent ? studentForm : emailForm,
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      label: '오류 메시지',
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
