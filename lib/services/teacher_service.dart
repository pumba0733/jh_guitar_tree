import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';

class TeacherService {
  final SupabaseClient _client = Supabase.instance.client;

  Future<bool> existsByEmail(String email) async {
    final res = await _client
        .from(SupabaseTables.teachers)
        .select('id')
        .ilike('email', email.trim())
        .limit(1);
    return res.isNotEmpty;
  }

  // (선택) 관리자 여부를 teachers 테이블로 판별하고 싶다면:
  // 1) 스키마에 is_admin boolean 컬럼 추가:
  //    ALTER TABLE teachers ADD COLUMN is_admin boolean DEFAULT false;
  // 2) 아래 메서드로 판별:
  // Future<bool> isAdminByEmail(String email) async {
  //   final res = await _client
  //       .from(SupabaseTables.teachers)
  //       .select('is_admin')
  //       .ilike('email', email.trim())
  //       .limit(1);
  //   if (res.isEmpty) return false;
  //   final row = res.first;
  //   return (row['is_admin'] as bool?) ?? false;
  // }
}
