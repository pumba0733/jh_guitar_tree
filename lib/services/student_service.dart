import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/student.dart';

class StudentService {
  final SupabaseClient _client = Supabase.instance.client;

  Future<Student?> findByNameAndLast4({
    required String name,
    required String last4,
  }) async {
    // 정확 매칭을 권장. ilike는 부분일치이므로, 동명이인 이슈 시 eq로 바꿔도 됨.
    final res = await _client
        .from(SupabaseTables.students)
        .select()
        .ilike('name', name.trim())
        .eq('phone_last4', last4.trim())
        .limit(1);

    if (res.isEmpty) return null;
    return Student.fromMap(res.first);
  }
}
