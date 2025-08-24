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
        .select('id, name, email')
        .eq('email', email.trim())
        .limit(1);
    if (res is List && res.isNotEmpty) {
      return Teacher.fromMap(Map<String, dynamic>.from(res.first));
    }
    return null;
  }
}
