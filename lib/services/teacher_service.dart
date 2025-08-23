// lib/services/teacher_service.dart
// v1.05 | 2025-08-24 | 이메일 존재 여부 확인 (역할 판별용)
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';

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
      return res.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
