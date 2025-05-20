// 📄 lib/screens/auth/login_screen.dart

import 'package:flutter/material.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('🎸 JH Guitar Tree 로그인 화면', style: TextStyle(fontSize: 20)),
      ),
    );
  }
}
