// lib/services/teacher_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/teacher.dart';

class TeacherService {
  final SupabaseClient _client = Supabase.instance.client;

  /// teachers.email 정확 일치 여부
  Future<bool> existsByEmail(String email) async {
    if (email.trim().isEmpty) return false;
    try {
      final res = await _client
          .from(SupabaseTables.teachers)
          .select('id')
          .eq('email', email.trim())
          .limit(1);
      return res is List && res.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Teacher?> getByEmail(String email) async {
    if (email.trim().isEmpty) return null;
    final res = await _client
        .from(SupabaseTables.teachers)
        .select('id, name, email, is_admin, auth_user_id')
        .eq('email', email.trim())
        .limit(1);
    if (res is List && res.isNotEmpty) {
      return Teacher.fromMap(Map<String, dynamic>.from(res.first));
    }
    return null;
  }

  /// 이메일로 Auth 사용자와 teachers 링크를 강제 동기화 (RPC)
  Future<String?> syncAuthUserIdByEmail(String email) async {
    final out = await _client.rpc(
      'sync_teacher_auth_by_email',
      params: {'p_email': email.trim()},
    );
    return out?.toString();
  }

  /// 로그인 직후 현재 Auth 사용자 id를 teachers와 링크(없으면 upsert)
  Future<void> syncCurrentAuthUserLink() async {
    final u = _client.auth.currentUser;
    if (u == null) return;
    final email = u.email ?? '';
    if (email.isEmpty) return;

    // teachers에 없으면 생성, 있으면 auth_user_id / last_login 갱신
    await _client.from(SupabaseTables.teachers).upsert({
      'email': email,
      'name': email.split('@').first,
      'auth_user_id': u.id,
      'last_login': DateTime.now().toIso8601String(),
    }, onConflict: 'email');

    // 최종 보정 (관리자 권한 포함) – RPC로 Auth 메타데이터 반영
    await syncAuthUserIdByEmail(email);
  }

  /// 강사 회원가입(앱에서 생성) — Supabase Auth + teachers upsert
  Future<bool> registerTeacher({
    required String name,
    required String email,
    required String password,
    bool isAdmin = false,
  }) async {
    final signUp = await _client.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'role': isAdmin ? 'admin' : 'teacher'},
    );
    if (signUp.user == null) return false;

    await _client.from(SupabaseTables.teachers).upsert({
      'email': email.trim(),
      'name': name.trim().isEmpty ? email.split('@').first : name.trim(),
      'is_admin': isAdmin,
      'auth_user_id': signUp.user!.id,
    }, onConflict: 'email');

    return true;
  }
}
