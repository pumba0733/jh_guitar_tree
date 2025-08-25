// lib/services/teacher_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/teacher.dart';

class TeacherService {
  final SupabaseClient _client = Supabase.instance.client;

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

  /// ✅ SQL의 실제 함수명으로 정정: sync_auth_user_id_by_email
  Future<void> syncAuthUserIdByEmail(String email) async {
    await _client.rpc(
      'sync_auth_user_id_by_email', // <-- 이름 일치
      params: {'p_email': email.trim()},
    );
  }

  /// ✅ 로그인 직후 연동은 "upsert_teacher_min → sync_auth_user_id_by_email" RPC만 사용
  Future<void> syncCurrentAuthUserLink() async {
    final u = _client.auth.currentUser;
    if (u == null) return;
    final email = (u.email ?? '').trim();
    if (email.isEmpty) return;

    // 1) 없으면 생성(최소필드) / 있으면 이름/관리자 플래그 보정
    await _client.rpc(
      'upsert_teacher_min',
      params: {
        'p_email': email,
        'p_name': email.split('@').first,
        'p_is_admin':
            (u.userMetadata?['role']?.toString().toLowerCase() == 'admin'),
      },
    );

    // 2) auth.uid()를 teachers.auth_user_id에 링크 + last_login 갱신
    await syncAuthUserIdByEmail(email);
  }

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

    // 가입 후에도 테이블 직접 upsert하지 않고 RPC로만 정리
    await _client.rpc(
      'upsert_teacher_min',
      params: {
        'p_email': email.trim(),
        'p_name': name.trim().isEmpty ? email.split('@').first : name.trim(),
        'p_is_admin': isAdmin,
      },
    );
    await syncAuthUserIdByEmail(email.trim());
    return true;
  }
}
