// lib/services/auth_service.dart
// v1.57.0 | 로그인 보강
// - 학생 로그인: RPC 시그니처(find_student(p_name, p_phone_last4)) 직접 호출 + 서비스 폴백
// - 교사/관리자 로그인 기존 로직 유지

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/student.dart';
import '../models/teacher.dart';
import 'student_service.dart';

enum UserRole { student, teacher, admin }

class AuthService {
  static final AuthService _i = AuthService._internal();
  factory AuthService() => _i;
  AuthService._internal();

  final StudentService _studentService = StudentService();
  final SupabaseClient _client = Supabase.instance.client;

  Student? _currentStudent;
  Teacher? _currentTeacher;

  Student? get currentStudent => _currentStudent;
  Teacher? get currentTeacher => _currentTeacher;

  bool get isLoggedInAsStudent => _currentStudent != null;
  bool get isLoggedInAsTeacher => _currentTeacher != null;

  User? get currentAuthUser => _client.auth.currentUser;
  bool get isTeacherLike => _currentTeacher != null && !isLoggedInAsStudent;

  // ---------------- 학생 로그인 ----------------
  Future<bool> signInStudent({
    required String name,
    required String last4,
  }) async {
    final n = name.trim();
    final l4 = last4.trim();

    // 1) 권장 경로: DB RPC (정확한 파라미터명/순서)
    try {
      final res = await _client.rpc(
        'find_student',
        params: {'p_name': n, 'p_phone_last4': l4},
      );

      Map<String, dynamic>? row;
      if (res is List && res.isNotEmpty) {
        final m = res.first;
        if (m is Map) row = Map<String, dynamic>.from(m);
      } else if (res is Map) {
        row = Map<String, dynamic>.from(res);
      }

      if (row != null) {
        _currentStudent = Student.fromMap(row);
        _currentTeacher = null;
        return true;
      }
    } catch (_) {
      // RPC 미존재/권한/기타 오류 → 폴백으로 진행
    }

    // 2) 폴백: 기존 StudentService 경로 (내부 구현 시그니처가 잘못되어 있어도 일단 시도)
    final found = await _studentService.findByNameAndLast4(name: n, last4: l4);
    if (found == null) return false;

    _currentStudent = found;
    _currentTeacher = null;
    return true;
  }

  // ---------------- 강사/관리자 로그인 ----------------
  String _normEmail(String v) => v.trim().toLowerCase();
  String _sha256Hex(String v) => sha256.convert(utf8.encode(v)).toString();

  Future<Map<String, dynamic>?> _rpcAppLoginTeacher({
    required String email,
    required String pwdHash,
  }) async {
    try {
      final res = await _client.rpc(
        'app_login_teacher',
        params: {'p_email': email, 'p_password_hash': pwdHash},
      );
      if (res == null) return null;
      if (res is List && res.isNotEmpty) {
        return Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
      return null;
    } catch (_) {
      return null; // 함수 없음/권한/기타 → 폴백 허용
    }
  }

  Future<bool> signInTeacherAdmin({
    required String email,
    required String password,
  }) async {
    final e = _normEmail(email);
    if (e.isEmpty) return false;

    final pwdHash = _sha256Hex(password);

    // 0) 교사 최소 레코드 보장(권한 상 anon도 호출 가능, is_admin은 null 유지)
    try {
      await _client.rpc(
        'upsert_teacher_min',
        params: {
          'p_email': e,
          'p_name': e.split('@').first,
          'p_is_admin': null, // 여기서 관리자 승격은 안 함(이미 DB에 true이므로 OK)
        },
      );
    } catch (_) {}

    // 1) Supabase Auth 세션 보장: SignIn → 실패시 SignUp → 다시 SignIn
    Future<bool> _ensureAuthSession() async {
      try {
        await _client.auth.signInWithPassword(email: e, password: password);
        return true;
      } catch (_) {
        /* 계속 진행 */
      }
      try {
        await _client.auth.signUp(email: e, password: password);
      } catch (_) {
        /* 이미 있을 수 있음 */
      }
      try {
        await _client.auth.signInWithPassword(email: e, password: password);
        return true;
      } catch (_) {
        return false;
      }
    }

    if (!await _ensureAuthSession()) return false;

    // 2) auth.uid ↔ teachers.auth_user_id 링크 + 마지막 로그인 시간
    try {
      await _client.rpc('sync_auth_user_id_by_email', params: {'p_email': e});
    } catch (_) {}
    try {
      final rows = await _client
          .from('teachers')
          .select(
            'id, name, email, is_admin, password_hash, auth_user_id, last_login',
          )
          .eq('email', e)
          .limit(1);
      if (rows.isEmpty) return false;

      final m = Map<String, dynamic>.from(rows.first);
      final stored = (m['password_hash'] as String?)?.trim() ?? '';
      if (stored.isNotEmpty && stored != pwdHash) {
        // 테이블 비번 정책을 쓰는 경우: 불일치면 로그인 실패 처리(선택)
        return false;
      }

      // last_login 갱신(실패 무시)
      try {
        await _client
            .from('teachers')
            .update({'last_login': DateTime.now().toUtc().toIso8601String()})
            .eq('email', e);
      } catch (_) {}

      // 최종 세션/역할 세팅
      _currentStudent = null;
      _currentTeacher = Teacher.fromMap(m);
      return true;
    } catch (_) {
      return false;
    }
  }


  // ---------------- 로그아웃 ----------------
  Future<void> signOutAll() async {
    _currentStudent = null;
    _currentTeacher = null;
    try {
      await _client.auth.signOut();
    } catch (_) {}
  }

  // ---------------- 역할 판별 ----------------
  Future<UserRole> getRole() async {
    if (isLoggedInAsStudent) return UserRole.student;
    final t = _currentTeacher;
    if (t == null) {
      throw StateError('로그인 정보가 없습니다');
    }
    return t.isAdmin ? UserRole.admin : UserRole.teacher;
  }

  // ---------------- 세션-링크 보강 ----------------
  Future<void> ensureTeacherLink() async {
    final email = _client.auth.currentUser?.email; // nullable
    if (email == null || email.isEmpty) return;
    try {
      await _client.rpc(
        'sync_auth_user_id_by_email',
        params: {'p_email': email},
      );
    } catch (_) {}
  }
}
