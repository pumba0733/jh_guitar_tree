// lib/services/auth_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/student.dart';
import 'student_service.dart';
import 'teacher_service.dart';

enum UserRole { student, teacher, admin }

class AuthService {
  static final AuthService _i = AuthService._internal();
  factory AuthService() => _i;
  AuthService._internal();

  final StudentService _studentService = StudentService();
  final TeacherService _teacherService = TeacherService();
  Student? _currentStudent;

  Student? get currentStudent => _currentStudent;
  bool get isLoggedInAsStudent => _currentStudent != null;
  User? get currentAuthUser => Supabase.instance.client.auth.currentUser;

  // 학생 간편 로그인
  Future<bool> signInStudent({required String name, required String last4}) async {
    final found = await _studentService.findByNameAndLast4(name: name, last4: last4);
    if (found == null) return false;
    _currentStudent = found;
    return true;
  }

  // 교사/관리자 이메일 로그인
  Future<bool> signInWithEmail({required String email, required String password}) async {
    final exists = await _teacherService.existsByEmail(email);
    if (!exists) return false;
    final res = await Supabase.instance.client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    return res.user != null;
  }

  Future<void> signOutAll() async {
    _currentStudent = null;
    await Supabase.instance.client.auth.signOut();
  }

  /// 현재 역할 판별
  Future<UserRole> getRole() async {
    // 학생 세션
    if (isLoggedInAsStudent) return UserRole.student;

    // 이메일 로그인 사용자
    final u = currentAuthUser;
    if (u == null) return UserRole.teacher; // 비정상 세션: 기본 teacher

    // 관리자: user_metadata.role == 'admin'
    final metaRole = u.userMetadata?['role'];
    if (metaRole is String && metaRole.toLowerCase() == 'admin') {
      return UserRole.admin;
    }
    return UserRole.teacher;
  }
}
