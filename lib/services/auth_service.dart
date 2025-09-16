// lib/services/auth_service.dart
// v1.44.5 | App-Auth 보강 + nullable 흐름 제거(경고 해소)
// - row를 non-null 변수 rowMap으로 통일 (RPC/SELECT 어느 경로든 성공 시 값 보장)
// - 불필요한 non-null assertion(!) 제거

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
    final found = await _studentService.findByNameAndLast4(
      name: name,
      last4: last4,
    );
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

    final h = _sha256Hex(password);

    // row를 non-null 변수로 수렴
    Map<String, dynamic>? rpcRow = await _rpcAppLoginTeacher(
      email: e,
      pwdHash: h,
    );
    Map<String, dynamic> rowMap;

    if (rpcRow != null) {
      rowMap = rpcRow;
    } else {
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
        if (stored.isEmpty || stored != h) return false;

        rowMap = m;
      } catch (_) {
        return false; // RLS 등으로 실패
      }
    }

    // 여기까지 오면 App-Auth OK (rowMap은 non-null 보장)
    final teacher = Teacher.fromMap(rowMap);
    _currentStudent = null;
    _currentTeacher = teacher;

    // (선택) 접속 흔적: Supabase 세션 이후 시도
    // 3) Supabase Auth 세션 만들기 (있으면 통과, 없으면 무음 실패)
    try {
      await _client.auth.signInWithPassword(email: e, password: password);
    } catch (_) {}

    // 4) auth.uid ↔ teachers.auth_user_id 동기화
    try {
      final authedEmail = _client.auth.currentUser?.email; // nullable
      if (authedEmail != null && authedEmail.isNotEmpty) {
        await _client.rpc(
          'sync_auth_user_id_by_email',
          params: {'p_email': authedEmail},
        );
      }
    } catch (_) {}

    // 5) 마지막 로그인 시간 업데이트(세션 있으면 성공 확률↑)
    try {
      final teacherId = teacher.id;
      await _client
          .from('teachers')
          .update({'last_login': DateTime.now().toUtc().toIso8601String()})
          .eq('id', teacherId);
    } catch (_) {}

    return true;
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
