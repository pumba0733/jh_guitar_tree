import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

class StudentHomeScreen extends StatelessWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final student = AuthService().currentStudent.value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('학생 홈'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await AuthService().logoutAll();
              if (context.mounted) {
                Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
              }
            },
          ),
        ],
      ),
      body: Center(
        child: Text(
          student == null ? '학생 정보 없음' : '환영합니다, ${student.name}님!',
          style: const TextStyle(fontSize: 20),
        ),
      ),
    );
  }
}
