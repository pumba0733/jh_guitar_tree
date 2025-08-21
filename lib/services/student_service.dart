// lib/services/student_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/student.dart';

class StudentService {
  final SupabaseClient _client = Supabase.instance.client;

  Future<Student?> findByNameAndLast4({
    required String name,
    required String last4,
  }) async {
    if (name.trim().isEmpty || last4.trim().length != 4) return null;

    final res = await _client
        .from(SupabaseTables.students)
        .select()
        .ilike('name', '%${name.trim()}%') // ← 와일드카드
        .eq('phone_last4', last4.trim())
        .limit(1);

    if (res.isEmpty) return null;
    return Student.fromMap(res.first);
  }
}
