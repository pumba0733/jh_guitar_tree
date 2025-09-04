// lib/services/auth_service.dart
// v1.33.3 | Auth + 학생간편로그인 + 역할판별(RPC 우선) + (B) 교사 링크 자동 동기화(직접 RPC)
// - 변경점(v1.33.3):
//   * 교사 이메일/비번 로그인 성공 시 _currentStudent = null 로 보정(역할 전환 안전성)
//   * 나머지는 v1.33.2와 동일

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/student.dart';
import 'student_service.dart';

enum UserRole { student, teacher, admin }

class AuthService {
  static final AuthService _i = AuthService._internal();
  factory AuthService() => _i;
  AuthService._internal();

  final StudentService _studentService = StudentService();

  Student? _currentStudent;

  Student? get currentStudent => _currentStudent;
  bool get isLoggedInAsStudent => _currentStudent != null;
  User? get currentAuthUser => Supabase.instance.client.auth.currentUser;

  /// 학생이 아니고 Auth 세션이 있으면 교사/관리자처럼 보임
  bool get isTeacherLike => currentAuthUser != null && !isLoggedInAsStudent;

  // ---- 내부 유틸 ----

  /// (B) 현재 Auth 유저의 이메일로 teachers.auth_user_id 링크 보장
  Future<void> _syncTeacherLinkIfPossible() async {
    final u = Supabase.instance.client.auth.currentUser;
    final email = u?.email?.trim();
    if (email == null || email.isEmpty) return;
    try {
      await Supabase.instance.client.rpc(
        'sync_auth_user_id_by_email',
        params: {'p_email': email},
      );
    } catch (_) {
      // 네트워크/권한 일시 오류는 조용히 무시 (RLS는 A 정책으로 폴백)
    }
  }

  // ---- 로그인들 ----

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
  }

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
      // 학생 세션 흔적 제거(역할 전환 안전)
      _currentStudent = null;
      // (B) 로그인 성공 시 교사 링크 동기화
      await _syncTeacherLinkIfPossible();
    }
    return ok;
  }

  /// 앱 시작/세션 복원 직후에 한 번 호출하면 좋음(선택).
  Future<void> ensureTeacherLink() async {
    await _syncTeacherLinkIfPossible();
  }

  Future<void> signOutAll() async {
    _currentStudent = null;
    await Supabase.instance.client.auth.signOut();
  }

  // ---- 역할 판별 ----

  /// 역할 판별: 1) 서버 RPC → 2) 메타데이터 → 3) teacher
  Future<UserRole> getRole() async {
    if (isLoggedInAsStudent) return UserRole.student;

    final u = currentAuthUser;
    if (u == null) {
      throw StateError('로그인 정보가 없습니다');
    }

    // (B) 혹시 세션 복원 직후 링크가 비어있을 수 있으므로 한 번 더 보장(무해)
    await _syncTeacherLinkIfPossible();

    // 1) 서버에서 관리자 여부를 직접 판정 (가장 신뢰 가능)
    try {
      final res =
          await Supabase.instance.client.rpc('is_current_user_admin') as bool?;
      if (res == true) return UserRole.admin;
    } catch (_) {
      // RPC 실패 시 아래로 폴백
    }

    // 2) 토큰 메타데이터에 명시된 경우 보조 신호로 인정
    final metaRole = u.userMetadata?['role'];
    if (metaRole is String && metaRole.toLowerCase() == 'admin') {
      return UserRole.admin;
    }

    // 3) 기본은 교사
    return UserRole.teacher;
  }
}
