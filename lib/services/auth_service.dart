// lib/services/auth_service.dart
// v1.58.0 | 세션 복원 & 링크 보강 + 학생/교사 상태 접근자 추가
// - B안 유지: 교사/관리자만 Supabase Auth 세션 사용, 학생은 앱 내부 엔터티로만 취급
// - restoreLinkedIdentities(): 앱 재시작/세션 복원 시 교사/학생 상태 재결합
// - ensureTeacherLink(): 이메일 기반 auth_user_id 동기화(기존 유지)
// - setCurrentStudent/clearCurrentStudent: 화면 간 공유를 위한 setter 제공
// - 2025-09-26 lint fix: unused_element(ignore) + no_leading_underscores_for_local_identifiers

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

  // ---- 상태 제어자 (학생 선택 유지용) ----
  void setCurrentStudent(Student? s) {
    _currentStudent = s;
  }

  void clearCurrentStudent() {
    _currentStudent = null;
  }

  // ---------------- 학생 로그인 (앱 내부 엔터티) ----------------
  // B안: Supabase Auth 세션을 만들지 않음. 학생은 내부 엔터티로만 사용.
  // lib/services/auth_service.dart

  Future<bool> signInStudent({
    required String name,
    required String last4,
  }) async {
    // ❶ 교사 세션 정리 후, 학생 전용(익명) 세션 시도
    try {
      await _client.auth.signOut();
    } catch (_) {}

    bool anonymousOk = false;
    try {
      await _client.auth.signInAnonymously();
      anonymousOk = true;
    } catch (e) {
      // 콘솔에만 경고 남기고 계속 진행(422: anonymous_provider_disabled)
      // 익명 비활성 상태면 attach_me_to_student / RLS가 풀리지 않음 → UI는 빈 목록일 수 있음
      // 반드시 Supabase에서 Anonymous provider 활성화 필요.
      // debugPrint('anonymous sign-in failed: $e');
    }

    final n = name.trim();
    final l4 = last4.trim();

    // 1) RPC 우선
    try {
      final res = await _client.rpc(
        'find_student',
        params: {'p_name': n, 'p_phone_last4': l4},
      );

      Map<String, dynamic>? row;
      if (res is List && res.isNotEmpty && res.first is Map) {
        row = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        row = Map<String, dynamic>.from(res);
      }
      if (row != null) {
        _currentStudent = Student.fromMap(row);
        // 익명 세션이 살아 있을 때만 attach 시도(없으면 조용히 스킵)
        if (anonymousOk) {
          try {
            await _client.rpc(
              'attach_me_to_student',
              params: {'p_student_id': _currentStudent!.id},
            );
          } catch (_) {}
        }
        return true;
      }
    } catch (_) {
      /* 폴백으로 진행 */
    }

    // 2) 폴백: 기존 StudentService 경로
    final found = await _studentService.findByNameAndLast4(name: n, last4: l4);
    if (found == null) return false;

    _currentStudent = found;
    if (anonymousOk) {
      try {
        await _client.rpc(
          'attach_me_to_student',
          params: {'p_student_id': _currentStudent!.id},
        );
      } catch (_) {}
    }
    return true;
  }

  // ---------------- 강사/관리자 로그인 ----------------
  String _normEmail(String v) => v.trim().toLowerCase();
  String _sha256Hex(String v) => sha256.convert(utf8.encode(v)).toString();

  // ignore: unused_element
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

    // 0) 최소 레코드 보장(실패 무시)
    try {
      await _client.rpc(
        'upsert_teacher_min',
        params: {
          'p_email': e,
          'p_name': e.split('@').first,
          'p_is_admin': null,
        },
      );
    } catch (_) {}

    // 1) Supabase Auth 세션 보장
    Future<bool> ensureAuthSession() async {
      try {
        await _client.auth.signInWithPassword(email: e, password: password);
        return true;
      } catch (_) {
        /* 계속 */
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

    if (!await ensureAuthSession()) return false;

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
        // 테이블 비번 정책 사용하는 경우: 불일치면 로그인 실패로 처리(선택)
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
      _currentTeacher = Teacher.fromMap(m);
      // 학생 상태는 유지(교사 전환 중이라면 필요 시 clear)
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

  // ---------------- 재시작 시 링크 복원 ----------------
  // 앱 부트스트랩에서 onAuthStateChange 직후 호출 권장.
  Future<void> restoreLinkedIdentities() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      _currentTeacher = null;
      // _currentStudent 는 화면(로컬 저장소 복원)에서 세팅하도록 둔다.
      return;
    }

    // 1) 교사 이메일 기반 링크 동기화 (최우선)
    try {
      final email = user.email;
      if (email != null && email.isNotEmpty) {
        await _client.rpc(
          'sync_auth_user_id_by_email',
          params: {'p_email': email},
        );
      }
    } catch (_) {}

    // 2) 교사 로드
    try {
      final rows = await _client
          .from('teachers')
          .select()
          .or('auth_user_id.eq.${user.id},email.eq.${user.email ?? ''}')
          .limit(1);
      if (rows.isNotEmpty) {
        _currentTeacher = Teacher.fromMap(
          Map<String, dynamic>.from(rows.first),
        );
      } else {
        _currentTeacher = null;
      }
    } catch (_) {
      _currentTeacher = null;
    }

    // 3) 학생은 B안에서 세션 주체가 아니므로 여기서 강제 복원하지 않음
    //    (학생 선택은 화면단에서 lastSelectedStudentId로 복원 → setCurrentStudent)
  }
}
