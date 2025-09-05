// lib/services/auth_service.dart
// v1.36.6 | App-Auth 전환: teachers.password_hash / is_admin 기반 로그인
// - 학생 간편로그인은 그대로 유지
// - 강사/관리자 로그인: Supabase Auth 사용 안 함
// - 역할 판별: 메모리의 _currentTeacher.isAdmin 으로 결정
// - 참고: 비밀번호 해시는 SHA-256(소문자 hex)

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
  Teacher? _currentTeacher; // ← App-Auth용

  Student? get currentStudent => _currentStudent;
  Teacher? get currentTeacher => _currentTeacher;

  bool get isLoggedInAsStudent => _currentStudent != null;
  bool get isLoggedInAsTeacher => _currentTeacher != null;

  /// (이전) Supabase Auth 유저 → 이제는 사용하지 않지만, 남아있는 코드 호환용
  User? get currentAuthUser => _client.auth.currentUser;

  /// 학생이 아니고 App-Auth 강사가 있으면 교사/관리자처럼 보임
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
    _currentTeacher = null; // 역할 전환 안전
    return true;
  }

  // ---------------- 강사/관리자 App-Auth 로그인 ----------------

  String _normEmail(String v) => v.trim().toLowerCase();

  String _sha256Hex(String v) =>
      sha256.convert(utf8.encode(v)).toString(); // 소문자 hex

  /// teachers(email) → password_hash 비교 후 메모리에 담아 로그인
  Future<bool> signInTeacherAdmin({
    required String email,
    required String password,
  }) async {
    final e = _normEmail(email);
    if (e.isEmpty) return false;

    // 필요한 필드만 조회
    final rows = await _client
        .from('teachers')
        .select(
          'id, name, email, is_admin, password_hash, auth_user_id, last_login',
        )
        .eq('email', e)
        .limit(1);

    if (rows is! List || rows.isEmpty) return false;

    final m = Map<String, dynamic>.from(rows.first);
    final stored = (m['password_hash'] as String?)?.trim() ?? '';
    if (stored.isEmpty) return false; // 비번 미설정 계정 보호

    final inputHex = _sha256Hex(password);
    if (stored != inputHex) return false;

    // 로그인 성공 → 메모리에 적재
    _currentStudent = null; // 역할 전환 안전
    _currentTeacher = Teacher.fromMap(m);

    // 접속 흔적만 남김(선택)
    try {
      await _client
          .from('teachers')
          .update({'last_login': DateTime.now().toUtc().toIso8601String()})
          .eq('id', _currentTeacher!.id);
    } catch (_) {
      // 로그 기록 실패는 무시
    }

    return true;
  }

  // ---------------- 로그아웃 ----------------

  Future<void> signOutAll() async {
    _currentStudent = null;
    _currentTeacher = null;
    // Supabase Auth를 쓰지 않아도, 혹시 남아있던 세션은 정리
    try {
      await _client.auth.signOut();
    } catch (_) {}
  }

  // ---------------- 역할 판별 ----------------

  /// App-Auth 기준: teacher.isAdmin → admin / teacher
  Future<UserRole> getRole() async {
    if (isLoggedInAsStudent) return UserRole.student;
    final t = _currentTeacher;
    if (t == null) {
      throw StateError('로그인 정보가 없습니다');
    }
    return t.isAdmin ? UserRole.admin : UserRole.teacher;
  }

  // ---------------- (구) 링크 동기화 더미 ----------------

  /// 기존 화면 호환용: 더 이상 필수 아님. 호출해도 무해.
  Future<void> ensureTeacherLink() async {
    // App-Auth 체계에서는 필수 동작이 없음.
    // 과거 RPC(sync_auth_user_id_by_email)를 쓰지 않습니다.
  }
}
