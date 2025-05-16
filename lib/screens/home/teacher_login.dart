import 'package:flutter/material.dart';

class TeacherLoginScreen extends StatefulWidget {
  const TeacherLoginScreen({super.key});

  @override
  State<TeacherLoginScreen> createState() => _TeacherLoginScreenState();
}

class _TeacherLoginScreenState extends State<TeacherLoginScreen> {
  String? _selectedName;
  final TextEditingController _passwordController = TextEditingController();

  final List<String> teacherNames = ['이재형', '홍길동', '김강사']; // 🔒 Firestore 연동 예정

  void _login() {
    if (_selectedName == null || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이름과 비밀번호를 입력해주세요.')));
      return;
    }

    // 🔐 실제 검증은 Firestore에서 진행 예정
    Navigator.pushReplacementNamed(context, '/teacher_home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('강사 로그인')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              value: _selectedName,
              decoration: const InputDecoration(labelText: '강사 이름'),
              items:
                  teacherNames
                      .map(
                        (name) =>
                            DropdownMenuItem(value: name, child: Text(name)),
                      )
                      .toList(),
              onChanged: (val) => setState(() => _selectedName = val),
            ),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '비밀번호'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: _login, child: const Text('로그인')),
          ],
        ),
      ),
    );
  }
}
