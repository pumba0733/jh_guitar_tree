// lib/services/teacher_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';

class TeacherService {
  final _client = Supabase.instance.client;

  Future<bool> existsByEmail(String email) async {
    if (email.trim().isEmpty) return false;
    final res = await _client
        .from(SupabaseTables.teachers)
        .select('id')
        .eq('email', email.trim())
        .limit(1);
    return res.isNotEmpty;
  }
}
