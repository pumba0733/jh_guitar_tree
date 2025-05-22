import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/screens/home/staff_portal_screen.dart';
import 'package:jh_guitar_tree/screens/home/student_home_screen.dart';
import 'package:jh_guitar_tree/services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController nameController = TextEditingController();
  String selectedRole = 'student';

  void handleLogin() {
    final name = nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이름을 입력해주세요')));
      return;
    }

    // ✅ 로그인 후 AuthService에 사용자 정보 저장
    AuthService().setUser(name, selectedRole);

    // ✅ 역할에 따라 이동
    if (selectedRole == 'student') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const StudentHomeScreen()),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const StaffPortalScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('로그인')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: '이름'),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: selectedRole,
              items: const [
                DropdownMenuItem(value: 'student', child: Text('학생')),
                DropdownMenuItem(value: 'teacher', child: Text('강사')),
                DropdownMenuItem(value: 'admin', child: Text('관리자')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    selectedRole = value;
                  });
                }
              },
              decoration: const InputDecoration(labelText: '역할'),
            ),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: handleLogin, child: const Text('로그인')),
          ],
        ),
      ),
    );
  }
}
