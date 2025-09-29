// lib/services/teacher_service.dart
// v1.37.2 | 타입체크 경고 제거 + maybeSingle() 사용
// - 불필요한 `res is List` / `res is! List` 제거
// - 단일 행 조회는 .maybeSingle()로 단순화
// - 목록 조회는 List<dynamic> 명시 캐스팅 후 사용

import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase/supabase_tables.dart';
import '../models/teacher.dart';

class TeacherService {
  final SupabaseClient _client = Supabase.instance.client;

  String _normEmail(String email) => email.trim().toLowerCase();
  String _sha256(String s) => crypto.sha256.convert(utf8.encode(s)).toString();

  Future<bool> existsByEmail(String email) async {
    final e = _normEmail(email);
    if (e.isEmpty) return false;
    try {
      final row = await _client
          .from(SupabaseTables.teachers)
          .select('id')
          .eq('email', e)
          .limit(1)
          .maybeSingle();
      return row != null;
    } catch (_) {
      return false;
    }
  }

  Future<Teacher?> getByEmail(String email) async {
    final e = _normEmail(email);
    if (e.isEmpty) return null;
    final row = await _client
        .from(SupabaseTables.teachers)
        .select('id, name, email, is_admin, auth_user_id, last_login')
        .eq('email', e)
        .limit(1)
        .maybeSingle();
    if (row == null) return null;
    return Teacher.fromMap(Map<String, dynamic>.from(row));
  }

  Future<List<Teacher>> listBasic({int limit = 500}) async {
    final res = await _client
        .from(SupabaseTables.teachers)
        .select('id, name, email, is_admin, auth_user_id, last_login')
        .order('name', ascending: true)
        .limit(limit);

    final list = (res as List).cast<dynamic>();
    return list
        .map((e) => Teacher.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);
  }

  Future<Map<String, String>> namesByIds(Iterable<String> ids) async {
    final list = ids.where((e) => e.trim().isNotEmpty).toSet().toList();
    if (list.isEmpty) return {};
    final res = await _client
        .from(SupabaseTables.teachers)
        .select('id, name')
        .inFilter('id', list);

    final rows = (res as List).cast<dynamic>();
    final map = <String, String>{};
    for (final row in rows) {
      final m = Map<String, dynamic>.from(row as Map);
      final id = (m['id'] ?? '').toString();
      final name = (m['name'] ?? '').toString();
      if (id.isNotEmpty) map[id] = name;
    }
    return map;
  }

  // (구) Auth 링크 관련 함수는 남겨두되 사용 안 함
  Future<void> syncAuthUserIdByEmail(String email) async {
    final e = _normEmail(email);
    await _client.rpc('sync_auth_user_id_by_email', params: {'p_email': e});
  }


  // App-Auth 전용 등록: Supabase Auth 계정 생성 안 함 (4자리 비번 허용)
  Future<bool> registerTeacher({
    required String name,
    required String email,
    required String password,
    bool isAdmin = false,
  }) async {
    final e = _normEmail(email);

    // 1) 앱용 teachers row 최소 보장
    await _client.rpc(
      'upsert_teacher_min',
      params: {
        'p_email': e,
        'p_name': name.trim().isEmpty ? e.split('@').first : name.trim(),
        'p_is_admin': isAdmin, // 서버에서 가드됨
      },
    );

    // 2) 앱-내 비밀번호 해시 저장 (이메일 기준)
    await updatePasswordSha256ByEmail(email: e, newPassword: password);

    // (선택) Supabase Auth 계정은 만들지 않음
    return true;
  }

  Future<void> updateBasic({
    required String id,
    required String name,
    required String email,
  }) async {
    final e = _normEmail(email);
    await _client
        .from(SupabaseTables.teachers)
        .update({'name': name.trim(), 'email': e})
        .eq('id', id);
  }

  Future<void> setAdmin({required String id, required bool isAdmin}) async {
    await _client
        .from(SupabaseTables.teachers)
        .update({
          'is_admin': isAdmin,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', id);
  }

  // 🔒 삭제: 실제 삭제 행을 검사 (0건이면 예외 발생)
  Future<void> deleteTeacher(String id) async {
    final res = await _client
        .from(SupabaseTables.teachers)
        .delete()
        .eq('id', id)
        .select('id'); // 삭제된 행 목록 반환
    final rows = (res as List).cast<dynamic>();
    if (rows.isEmpty) {
      throw Exception('delete_failed_or_denied');
    }
  }

  // ===== 비밀번호 해시 관리 (이메일 기준) =====
  Future<void> updatePasswordSha256ByEmail({
    required String email,
    required String newPassword,
  }) async {
    final hashed = _sha256(newPassword.trim());
    final e = _normEmail(email);
    await _client.rpc(
      'set_teacher_password_hash',
      params: {'p_email': e, 'p_password_hash': hashed},
    );
  }

  Future<bool> verifyLocalPassword(String email, String password) async {
    final e = _normEmail(email);
    final row = await _client
        .from(SupabaseTables.teachers)
        .select('password_hash')
        .eq('email', e)
        .limit(1)
        .maybeSingle();

    if (row == null) return false;
    final stored = (row['password_hash'] as String?)?.trim() ?? '';
    if (stored.isEmpty) return false;
    return stored == _sha256(password.trim());
  }
}
