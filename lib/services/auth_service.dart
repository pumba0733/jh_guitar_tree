// lib/services/auth_service.dart
// v1.77.1 | 테이블 인증 전용 + 호환용 게터 복구
// - Supabase Auth 의존 제거 유지
// - 학생: StudentService로만 로그인/상태 유지
// - 강사/관리자: teachers(email + password_hash)로 검증
// - getRole(): Teacher.isAdmin으로 판별
// - signOutAll(): 로컬 상태만 클리어
// - ✅ 호환용 게터 복구:
//     * User? get currentAuthUser => null;  // 더 이상 Auth 세션 없음 (null 고정)
//     * bool get isTeacherLike => _currentTeacher != null && _currentStudent == null;

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

  // ✅ 호환용: 예전 코드가 참조하는 Auth 세션 사용자 (이제는 null 고정)
  User? get currentAuthUser => null;

  // ✅ 호환용: 예전 코드가 참조하는 "교사 비슷" 판단
  bool get isTeacherLike => _currentTeacher != null && _currentStudent == null;

  // ---- 상태 제어자 (학생 선택 유지용) ----
  void setCurrentStudent(Student? s) {
    _currentStudent = s;
  }

  void clearCurrentStudent() {
    _currentStudent = null;
  }

  // ---------------- 학생 로그인 (테이블만) ----------------
  Future<bool> signInStudent({
    required String name,
    required String last4,
  }) async {
    final n = name.trim();
    final l4 = last4.trim();

    final found = await _studentService.findByNameAndLast4(name: n, last4: l4);
    if (found == null) return false;

    _currentStudent = found;
    return true;
  }

  // ---------------- 강사/관리자 로그인 (테이블만) ----------------
  String _normEmail(String v) => v.trim().toLowerCase();
  String _sha256Hex(String v) => sha256.convert(utf8.encode(v)).toString();

  Future<bool> signInTeacherAdmin({
    required String email,
    required String password,
  }) async {
    final e = _normEmail(email);
    if (e.isEmpty) return false;
    final pwdHash = _sha256Hex(password);

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
      if (stored.isEmpty || stored != pwdHash) {
        return false;
      }

      // last_login 갱신(실패 무시)
      try {
        await _client
            .from('teachers')
            .update({'last_login': DateTime.now().toUtc().toIso8601String()})
            .eq('email', e);
      } catch (_) {}

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
    // Supabase Auth 사용 안함 → auth.signOut() 호출 없음
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

  // ---------------- (호환 스텁) 링크/복원 ----------------
  Future<void> ensureTeacherLink() async {
    // no-op (테이블 인증)
  }

  Future<void> restoreLinkedIdentities() async {
    // 앱 재시작 시 Auth 세션 복원 없음 → 로컬 상태만 초기화
    _currentTeacher = null;
    // _currentStudent는 화면단에서 복원(setCurrentStudent) 사용
  }
}
