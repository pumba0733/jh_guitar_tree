import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/screens/auth/login_screen.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  String? _currentUserId;
  String? _currentUserRole; // 'student', 'teacher', 'admin'

  String? get currentUserId => _currentUserId;
  String? get currentUserRole => _currentUserRole;

  bool get isTeacher => _currentUserRole == 'teacher';
  bool get isAdmin => _currentUserRole == 'admin';

  Future<Widget> getInitialScreen() async {
    _currentUserId = null;
    _currentUserRole = null;
    return const LoginScreen();
  }

  void setUser(String userId, String role) {
    _currentUserId = userId;
    _currentUserRole = role;
  }

  Future<void> logout(BuildContext context) async {
    _currentUserId = null;
    _currentUserRole = null;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }
}
