// lib/screens/auth/login_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

enum LoginRole { student, teacher, admin }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
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
      final auth = AuthService();

      if (_role == LoginRole.student) {
        final ok = await auth.signInStudent(
          name: _studentNameCtrl.text,
          last4: _studentLast4Ctrl.text,
        );
        if (!ok) throw Exception('학생을 찾을 수 없습니다.');
        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.studentHome, (_) => false);
        }
        return;
      }

      // teacher/admin email login
      final ok = await auth.signInWithEmail(
        email: _emailCtrl.text,
        password: _passwordCtrl.text,
      );
      if (!ok) throw Exception('이메일 또는 비밀번호가 올바르지 않습니다.');

      final role = await auth.getRole();
      final route = switch (role) {
        UserRole.admin => AppRoutes.adminHome,
        _ => AppRoutes.teacherHome,
      };
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
      }
    } catch (e) {
      setState(() => _error = '$e');
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roleTabs = ToggleButtons(
      isSelected: [
        _role == LoginRole.student,
        _role == LoginRole.teacher,
        _role == LoginRole.admin
      ],
      onPressed: (i) => _setRole(LoginRole.values[i]),
      children: const [
        Padding(padding: EdgeInsets.all(8), child: Text('학생')),
        Padding(padding: EdgeInsets.all(8), child: Text('강사')),
        Padding(padding: EdgeInsets.all(8), child: Text('관리자')),
      ],
    );

    final studentForm = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _studentNameCtrl,
          decoration: const InputDecoration(labelText: '학생 이름'),
          inputFormatters: [LengthLimitingTextInputFormatter(20)],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _studentLast4Ctrl,
          decoration: const InputDecoration(labelText: '전화번호 뒤 4자리'),
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4),
          ],
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _loading ? null : _submit,
          child: _loading ? const CircularProgressIndicator() : const Text('학생 로그인'),
        ),
      ],
    );

    final emailForm = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _emailCtrl,
          decoration: const InputDecoration(labelText: '이메일'),
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordCtrl,
          decoration: const InputDecoration(labelText: '비밀번호'),
          obscureText: true,
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _loading ? null : _submit,
          child: _loading ? const CircularProgressIndicator() : const Text('이메일 로그인'),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('로그인')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                roleTabs,
                const SizedBox(height: 20),
                if (_role == LoginRole.student) studentForm else emailForm,
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
