import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentAuthUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('홈 화면'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await AuthService().logoutAll(); // ✅ signOut → logoutAll 교체
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
          user == null ? '로그인 필요' : '환영합니다, ${user.email ?? '사용자'}!',
          style: const TextStyle(fontSize: 20),
        ),
      ),
    );
  }
}
