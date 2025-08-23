// lib/services/student_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/student.dart';

class StudentService {
  final SupabaseClient _client = Supabase.instance.client;

  /// 이름(부분일치) + 전화 뒷자리 4자리(정확 일치)로 학생 1명을 조회
  Future<Student?> findByNameAndLast4({
    required String name,
    required String last4,
  }) async {
    final nameTrim = name.trim();
    final last4Trim = last4.trim();
    if (nameTrim.isEmpty || last4Trim.length != 4) return null;

    final res = await _client
        .from(SupabaseTables.students)
        .select()
        .ilike('name', '%$nameTrim%')
        .eq('phone_last4', last4Trim)
        .limit(1);

    if (res.isEmpty) return null;
    return Student.fromMap(res.first);
  }
}
