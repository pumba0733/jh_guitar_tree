import 'package:flutter/material.dart';

class StaffLoginDialog extends StatefulWidget {
  const StaffLoginDialog({super.key});

  @override
  State<StaffLoginDialog> createState() => _StaffLoginDialogState();
}

class _StaffLoginDialogState extends State<StaffLoginDialog> {
  String selectedRole = 'teacher';
  String emailOrDropdown = '';
  String password = '';
  final List<String> teacherNames = ['이재형', '홍길동', '고길동'];

  void _handleLogin() {
    Navigator.pop(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('로그인 시도됨')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('관리자 / 강사 로그인'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 역할 선택
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Radio<String>(
                value: 'teacher',
                groupValue: selectedRole,
                onChanged: (value) => setState(() => selectedRole = value!),
              ),
              const Text('강사'),
              const SizedBox(width: 20),
              Radio<String>(
                value: 'admin',
                groupValue: selectedRole,
                onChanged: (value) => setState(() => selectedRole = value!),
              ),
              const Text('관리자'),
            ],
          ),
          const SizedBox(height: 12),

          // 입력 필드
          selectedRole == 'teacher'
              ? DropdownButtonFormField<String>(
                value: emailOrDropdown.isNotEmpty ? emailOrDropdown : null,
                hint: const Text('강사 선택'),
                items:
                    teacherNames.map((name) {
                      return DropdownMenuItem<String>(
                        value: name,
                        child: Text(name),
                      );
                    }).toList(),
                onChanged: (value) => setState(() => emailOrDropdown = value!),
              )
              : TextField(
                decoration: const InputDecoration(hintText: '이메일 입력'),
                onChanged: (value) => emailOrDropdown = value.trim(),
              ),

          const SizedBox(height: 12),

          // 비밀번호 입력
          TextField(
            obscureText: true,
            decoration: const InputDecoration(hintText: '비밀번호 입력'),
            onChanged: (value) => password = value,
            onSubmitted: (_) => _handleLogin(), // Enter 시 로그인
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context), // ESC 대체
          child: const Text('취소'),
        ),
        ElevatedButton(onPressed: _handleLogin, child: const Text('로그인 ▶')),
      ],
    );
  }
}
