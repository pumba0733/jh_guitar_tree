import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentAuthUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('관리자 홈'),
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
          user == null ? '로그인 필요' : '관리자님 환영합니다, ${user.email ?? ''}',
          style: const TextStyle(fontSize: 20),
        ),
      ),
    );
  }
}
