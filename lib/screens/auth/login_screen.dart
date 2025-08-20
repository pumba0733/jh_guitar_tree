import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

enum LoginRole { student, teacher, admin }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  LoginRole _role = LoginRole.student;

  final _studentNameCtrl = TextEditingController();
  final _studentLast4Ctrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _loading = false;
  String? _error;

  void _setRole(LoginRole r) {
    setState(() {
      _role = r;
      _error = null;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_role == LoginRole.student) {
        final ok = await AuthService().loginStudent(
          name: _studentNameCtrl.text,
          last4: _studentLast4Ctrl.text,
        );
        if (!mounted) return;
        if (ok) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.studentHome);
        } else {
          setState(() => _error = '학생 정보가 일치하지 않습니다.');
        }
      } else {
        final email = _emailCtrl.text.trim();
        final pwd = _passwordCtrl.text.trim();
        if (email.isEmpty || pwd.isEmpty) {
          setState(() => _error = '이메일/비밀번호를 입력해주세요.');
        } else {
          await AuthService().loginWithEmailPassword(
            email: email,
            password: pwd,
          );

          if (!mounted) return;

          // ✅ v1.02: 로그인 후 역할 판정 → 각 홈으로 분기
          final role = await AuthService().getRole();
          switch (role) {
            case UserRole.admin:
              Navigator.of(context).pushReplacementNamed(AppRoutes.adminHome);
              break;
            case UserRole.teacher:
              Navigator.of(context).pushReplacementNamed(AppRoutes.teacherHome);
              break;
            case UserRole.student:
              Navigator.of(context).pushReplacementNamed(AppRoutes.studentHome);
              break;
          }
        }
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '로그인 중 오류가 발생했습니다: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildRoleSegment() {
    return SegmentedButton<LoginRole>(
      segments: const [
        ButtonSegment(value: LoginRole.student, label: Text('학생')),
        ButtonSegment(value: LoginRole.teacher, label: Text('강사')),
        ButtonSegment(value: LoginRole.admin, label: Text('관리자')),
      ],
      selected: {_role},
      onSelectionChanged: (set) => _setRole(set.first),
    );
  }

  Widget _buildStudentForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('학생 간편 로그인', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _studentNameCtrl,
          decoration: const InputDecoration(
            labelText: '이름',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _studentLast4Ctrl,
          decoration: const InputDecoration(
            labelText: '전화번호 뒷자리 4자리',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          maxLength: 4,
          onSubmitted: (_) => _submit(),
        ),
      ],
    );
  }

  Widget _buildEmailForm(String title) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _emailCtrl,
          decoration: const InputDecoration(
            labelText: '이메일',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _passwordCtrl,
          decoration: const InputDecoration(
            labelText: '비밀번호',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          onSubmitted: (_) => _submit(),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _studentNameCtrl.dispose();
    _studentLast4Ctrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_role) {
      LoginRole.student => '학생 로그인',
      LoginRole.teacher => '강사 로그인',
      LoginRole.admin => '관리자 로그인',
    };

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildRoleSegment(),
                const SizedBox(height: 16),
                if (_role == LoginRole.student) _buildStudentForm(),
                if (_role == LoginRole.teacher) _buildEmailForm('강사 로그인'),
                if (_role == LoginRole.admin) _buildEmailForm('관리자 로그인'),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('로그인'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
