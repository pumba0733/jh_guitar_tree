import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/services/teacher_service.dart';
import 'package:jh_guitar_tree/screens/home/staff_portal_screen.dart';
import 'package:jh_guitar_tree/models/teacher.dart';

class StaffLoginDialog extends StatefulWidget {
  const StaffLoginDialog({super.key});

  @override
  State<StaffLoginDialog> createState() => _StaffLoginDialogState();
}

class _StaffLoginDialogState extends State<StaffLoginDialog> {
  String selectedRole = 'teacher';
  String selectedName = '';
  String email = '';
  String password = '';
  List<Teacher> teachers = [];
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController emailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadTeachers();
  }

  Future<void> _loadTeachers() async {
    final loaded = await TeacherService.getAllTeachers();
    setState(() {
      teachers = loaded;
      if (teachers.isNotEmpty) {
        selectedName = teachers.first.name;
      }
    });
  }

  void _handleLogin() async {
    if (password.isEmpty) return;
    if (selectedRole == 'teacher' && selectedName.isEmpty) return;
    if (selectedRole == 'admin' && email.isEmpty) return;

    final identifier = selectedRole == 'teacher' ? selectedName : email;
    final teacher = await TeacherService.login(identifier, password);
    if (teacher == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그인 실패: 비밀번호가 일치하지 않거나 존재하지 않는 계정입니다.')),
      );
      return;
    }

    if (!mounted) return;
    Navigator.pop(context);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => StaffPortalScreen(teacher: teacher)),
    );
  }

  Widget _buildIdentityInput() {
    if (selectedRole == 'teacher') {
      return DropdownButton<String>(
        value: selectedName.isNotEmpty ? selectedName : null,
        hint: const Text('이름 선택'),
        isExpanded: true,
        items:
            teachers.map((t) {
              return DropdownMenuItem<String>(
                value: t.name,
                child: Text(t.name),
              );
            }).toList(),
        onChanged: (value) => setState(() => selectedName = value!),
      );
    } else {
      return TextField(
        controller: emailController,
        onChanged: (value) => email = value.trim(),
        onSubmitted: (_) => _handleLogin(), // ✅ 엔터로 로그인
        decoration: const InputDecoration(
          labelText: '이메일 입력',
          border: OutlineInputBorder(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('관리자 / 강사 로그인'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Radio<String>(
                value: 'teacher',
                groupValue: selectedRole,
                onChanged: (value) => setState(() => selectedRole = value!),
              ),
              const Text('강사'),
              Radio<String>(
                value: 'admin',
                groupValue: selectedRole,
                onChanged: (value) => setState(() => selectedRole = value!),
              ),
              const Text('관리자'),
            ],
          ),
          const SizedBox(height: 16),
          _buildIdentityInput(),
          const SizedBox(height: 16),
          TextField(
            controller: passwordController,
            obscureText: true,
            onChanged: (value) => password = value,
            onSubmitted: (_) => _handleLogin(), // ✅ 엔터로 로그인
            decoration: const InputDecoration(
              labelText: '비밀번호',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [TextButton(onPressed: _handleLogin, child: const Text('로그인'))],
    );
  }
}
