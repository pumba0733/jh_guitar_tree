// lib/services/teacher_service.dart
// v1.34.0 | 목록(listBasic) + 이름맵(namesByIds) 추가 / 이메일 정규화 유지
// - 기존 v1.33.0 대비 변경점:
//   1) listBasic(): 교사 기본 목록(id,name,email) 조회
//   2) namesByIds(): {teacherId: name} 맵 조회
//   3) 주석/가드 정리 (p_is_admin 전달 주의 그대로 유지)

import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/teacher.dart';

class TeacherService {
  final SupabaseClient _client = Supabase.instance.client;

  // 이메일 정규화: lower + trim
  String _normEmail(String email) => email.trim().toLowerCase();

  Future<bool> existsByEmail(String email) async {
    final e = _normEmail(email);
    if (e.isEmpty) return false;
    try {
      final res = await _client
          .from(SupabaseTables.teachers)
          .select('id')
          .eq('email', e)
          .limit(1);
      return res is List && res.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Teacher?> getByEmail(String email) async {
    final e = _normEmail(email);
    if (e.isEmpty) return null;
    final res = await _client
        .from(SupabaseTables.teachers)
        .select('id, name, email') // is_admin/auth_user_id는 여기선 불필요
        .eq('email', e)
        .limit(1);
    if (res is List && res.isNotEmpty) {
      return Teacher.fromMap(Map<String, dynamic>.from(res.first));
    }
    return null;
  }

  /// RPC: teachers.auth_user_id를 현재 auth.uid()로 동기화
  Future<void> syncAuthUserIdByEmail(String email) async {
    final e = _normEmail(email);
    await _client.rpc('sync_auth_user_id_by_email', params: {'p_email': e});
  }

  /// 로그인 직후 연동:
  /// 1) upsert_teacher_min: 최소 행 보장 (⚠️ p_is_admin 전달 금지)
  /// 2) sync_auth_user_id_by_email: auth_user_id, last_login 갱신
  Future<void> syncCurrentAuthUserLink() async {
    final u = _client.auth.currentUser;
    if (u == null) return;
    final email = _normEmail(u.email ?? '');
    if (email.isEmpty) return;

    await _client.rpc(
      'upsert_teacher_min',
      params: {
        'p_email': email,
        'p_name': email.split('@').first,
        // 'p_is_admin' 전달 금지: 서버에서만 관리
      },
    );

    await syncAuthUserIdByEmail(email);
  }

  /// 관리자(또는 서버키)만 isAdmin 반영 (서버 SQL 가드)
  Future<bool> registerTeacher({
    required String name,
    required String email,
    required String password,
    bool isAdmin = false,
  }) async {
    final e = _normEmail(email);
    final signUp = await _client.auth.signUp(
      email: e,
      password: password,
      data: {'role': isAdmin ? 'admin' : 'teacher'},
    );
    if (signUp.user == null) return false;

    await _client.rpc(
      'upsert_teacher_min',
      params: {
        'p_email': e,
        'p_name': name.trim().isEmpty ? e.split('@').first : name.trim(),
        'p_is_admin': isAdmin, // 비관리자 호출 시 서버에서 무시됨
      },
    );
    await syncAuthUserIdByEmail(e);
    return true;
  }

  // ===== [추가] 교사 목록 / 이름맵 =====

  /// 교사 기본 목록(id, name, email) 조회
  Future<List<Teacher>> listBasic({int limit = 500}) async {
    final res = await _client
        .from(SupabaseTables.teachers)
        .select('id, name, email')
        .order('name', ascending: true)
        .limit(limit);
    if (res is! List) return const [];
    return res
        .map((e) => Teacher.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 주어진 teacherId 목록을 {id: name} 맵으로 반환
  Future<Map<String, String>> namesByIds(Iterable<String> ids) async {
    final list = ids.where((e) => e.trim().isNotEmpty).toSet().toList();
    if (list.isEmpty) return {};
    final res = await _client
        .from(SupabaseTables.teachers)
        .select('id, name')
        .inFilter('id', list);
    if (res is! List) return {};
    final map = <String, String>{};
    for (final row in res) {
      final m = Map<String, dynamic>.from(row);
      map[m['id'] as String] = m['name'] as String;
    }
    return map;
  }
}
