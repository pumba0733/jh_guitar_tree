import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/student.dart';
import 'student_service.dart';

/// v1.01: 학생 간편 로그인(in-memory) + 기존 Supabase Auth(교사/관리자)
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
}
