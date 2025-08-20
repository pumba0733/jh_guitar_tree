import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/student.dart';
import 'student_service.dart';
import 'teacher_service.dart';

enum UserRole { student, teacher, admin }

/// v1.02: 학생 간편 로그인 + 이메일 로그인 후 역할 분기
class AuthService {
  static final AuthService _i = AuthService._internal();
  factory AuthService() => _i;
  AuthService._internal();

  final SupabaseClient _client = Supabase.instance.client;

  // 학생 세션(간편 로그인): 앱 내 임시 상태로만 유지
  final ValueNotifier<Student?> currentStudent = ValueNotifier<Student?>(null);

  // 교사/관리자: Supabase Auth 세션 사용
  User? get currentAuthUser => _client.auth.currentUser;

  bool get isLoggedInAsStudent => currentStudent.value != null;
  bool get isLoggedInAsAuthUser => currentAuthUser != null;

  Future<AuthResponse> loginWithEmailPassword({
    required String email,
    required String password,
  }) {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> logoutAll() async {
    currentStudent.value = null;
    await _client.auth.signOut();
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

  /// 이메일 로그인 성공 후 역할 판별
  ///
  /// 우선순위:
  /// 1) 학생 세션이면 student
  /// 2) auth.user.userMetadata.role == 'admin' → admin
  /// 3) teachers 테이블에 email 존재 → teacher
  /// 4) 기본값 teacher (필요 시 정책에 맞게 조정)
  Future<UserRole> getRole() async {
    if (isLoggedInAsStudent) return UserRole.student;

    final u = currentAuthUser;
    if (u == null) return UserRole.teacher; // 비정상 케이스 기본 처리

    final metaRole = u.userMetadata?['role'];
    if (metaRole is String && metaRole.toLowerCase() == 'admin') {
      return UserRole.admin;
    }

    final teacherService = TeacherService();
    final isTeacher = await teacherService.existsByEmail(u.email ?? '');
    if (isTeacher) return UserRole.teacher;

    // (옵션) teachers.is_admin 컬럼 기반으로 엄밀 판정하려면 위 주석 참고
    return UserRole.teacher;
  }
}
