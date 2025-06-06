import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/screens/auth/login_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JH Guitar Tree',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'AppleSDGothicNeo',
      ),
      home: const LoginScreen(),
    );
  }
}
