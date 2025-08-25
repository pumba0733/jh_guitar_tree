// lib/services/auth_service.dart
// v1.21.3 | Auth + 학생간편로그인 + 역할판별 + 교사 링크 동기화(로그인 후)

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

  // 화면들이 기대하는 공개 API
  Student? get currentStudent => _currentStudent;
  bool get isLoggedInAsStudent => _currentStudent != null;
  User? get currentAuthUser => Supabase.instance.client.auth.currentUser;

  // 학생 간편 로그인 (DB RPC find_student 기반)
  Future<bool> signInStudent({
    required String name,
    required String last4,
  }) async {
    final found = await _studentService.findByNameAndLast4(
      name: name,
      last4: last4,
    );
    if (found == null) return false;
    _currentStudent = found;
    return true;
    // 필요하면 여기서 logs 테이블에 login 기록 추가 가능
  }

  // 교사/관리자 이메일 로그인
  // ❗ 선행 existsByEmail 체크 제거: Auth 성공 후 teachers upsert + 동기화
  Future<bool> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final res = await Supabase.instance.client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    final ok = res.user != null;

    if (ok) {
      // 로그인 성공 → teachers.auth_user_id / last_login 동기화(+없으면 생성)
      await _teacherService.syncCurrentAuthUserLink();
    }
    return ok;
  }

  Future<void> signOutAll() async {
    _currentStudent = null;
    await Supabase.instance.client.auth.signOut();
  }

  /// 현재 역할 판별
  Future<UserRole> getRole() async {
    if (isLoggedInAsStudent) return UserRole.student;

    final u = currentAuthUser;
    if (u == null) return UserRole.teacher;

    // Supabase Auth user_metadata.role 기반 (admin / teacher)
    final metaRole = u.userMetadata?['role'];
    if (metaRole is String && metaRole.toLowerCase() == 'admin') {
      return UserRole.admin;
    }
    return UserRole.teacher;
  }
}
