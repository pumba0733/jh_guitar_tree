// lib/services/auth_service.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/student.dart';
import 'student_service.dart';
import 'teacher_service.dart';
import '../routes/app_routes.dart';

enum UserRole { student, teacher, admin }

/// v1.04: 학생 간편 로그인 + 이메일 로그인 + 역할 분기 + 라우팅 헬퍼
class AuthService {
  static final AuthService _i = AuthService._internal();
  factory AuthService() => _i;
  AuthService._internal();

  final SupabaseClient _client = Supabase.instance.client;

  /// 학생 세션(간편 로그인): 앱 내 임시 상태로만 유지
  final ValueNotifier<Student?> currentStudent = ValueNotifier<Student?>(null);

  /// 교사/관리자: Supabase Auth 세션 사용
  User? get currentAuthUser => _client.auth.currentUser;

  bool get isLoggedInAsStudent => currentStudent.value != null;
  bool get isLoggedInAsAuthUser => currentAuthUser != null;

  /// 이메일/비밀번호 로그인 (교사/관리자)
  Future<AuthResponse> loginWithEmailPassword({
    required String email,
    required String password,
  }) {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  /// 학생 간편 로그인: name + last4
  Future<bool> loginStudent({
    required String name,
    required String last4,
  }) async {
    final service = StudentService();
    final s = await service.findByNameAndLast4(
      name: name.trim(),
      last4: last4.trim(),
    );
    currentStudent.value = s;
    return s != null;
  }

  /// 로그아웃 (학생/교사/관리자 모두)
  Future<void> logoutAll() async {
    currentStudent.value = null; // 학생 세션 클리어
    await _client.auth.signOut(); // Supabase 세션 클리어
  }

  /// ✅ 역할 판별 메서드 (클래스 내부 메서드로 반드시 존재해야 함)
  Future<UserRole> getRole() async {
    // 1) 학생 간편 로그인 상태면 student
    if (isLoggedInAsStudent) return UserRole.student;

    // 2) Supabase Auth 사용자 확인
    final u = currentAuthUser;
    if (u == null) {
      // 비정상 케이스 기본 처리: teacher
      return UserRole.teacher;
    }

    // 3) user_metadata.role = 'admin' 인 경우 admin
    final metaRole = u.userMetadata?['role'];
    if (metaRole is String && metaRole.toLowerCase() == 'admin') {
      return UserRole.admin;
    }

    // 4) teachers 테이블에 email 존재 시 teacher
    final teacherService = TeacherService();
    final email = u.email ?? '';
    if (email.isNotEmpty) {
      final isTeacher = await teacherService.existsByEmail(email);
      if (isTeacher) return UserRole.teacher;
    }

    // 5) 기본값: teacher
    return UserRole.teacher;
  }

  /// ✅ 로그인 직후 역할에 따라 홈으로 이동하는 헬퍼
  Future<void> routeAfterLogin(BuildContext context) async {
    final role = await getRole();
    String target = AppRoutes.studentHome;
    if (role == UserRole.teacher) target = AppRoutes.teacherHome;
    if (role == UserRole.admin) target = AppRoutes.adminHome;

    if (context.mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil(target, (_) => false);
    }
  }
}
