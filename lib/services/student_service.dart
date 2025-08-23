// lib/services/student_service.dart
// v1.05: 테이블 직접 조회 → RPC 호출(find_student)로 전환
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/student.dart';
import '../constants/app_env.dart';

class StudentService {
  final SupabaseClient _client = Supabase.instance.client;

  Future<Student?> findByNameAndLast4({
    required String name,
    required String last4,
  }) async {
    final n = name.trim();
    final l4 = last4.trim();
    if (n.isEmpty || l4.length != 4) return null;

    // 1) 운영 기본: RPC
    try {
      final rpcRes = await _client.rpc(
        'find_student',
        params: {'p_name': n, 'p_last4': l4},
      );
      if (rpcRes is List && rpcRes.isNotEmpty) {
        return Student.fromMap(Map<String, dynamic>.from(rpcRes.first));
      }
    } catch (_) {
      // fall through to dev fallback
    }

    // 2) DEV 폴백(테이블 직접 조회). 운영(prod)에서는 사용 안 함.
    if (!AppEnv.isProd) {
      final res = await _client
          .from(SupabaseTables.students)
          .select()
          .ilike('name', '%$n%')
          .eq('phone_last4', l4)
          .limit(1);
      if (res is List && res.isNotEmpty) {
        return Student.fromMap(Map<String, dynamic>.from(res.first));
      }
    }

    return null;
  }
}
