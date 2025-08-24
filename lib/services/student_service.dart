// lib/services/student_service.dart
// find_student RPC + 이름 맵 조회
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import '../models/student.dart';

class StudentService {
  final SupabaseClient _client = Supabase.instance.client;

  Future<Student?> findByNameAndLast4({
    required String name,
    required String last4,
  }) async {
    final n = name.trim();
    final l4 = last4.trim();
    if (n.isEmpty || l4.length != 4) return null;

    // Prefer RPC (matches SQL provided).
    final rpcRes = await _client.rpc('find_student', params: {
      'p_name': n,
      'p_last4': l4,
    });
    if (rpcRes is Map && rpcRes.isNotEmpty) {
      return Student.fromMap(Map<String, dynamic>.from(rpcRes));
    }
    if (rpcRes is List && rpcRes.isNotEmpty) {
      return Student.fromMap(Map<String, dynamic>.from(rpcRes.first));
    }

    // Fallback to direct query (dev/staging where RPC might be missing).
    final res = await _client
        .from(SupabaseTables.students)
        .select()
        .eq('phone_last4', l4)
        .ilike('name', '%$n%')
        .limit(1);
    if (res is List && res.isNotEmpty) {
      return Student.fromMap(Map<String, dynamic>.from(res.first));
    }
    return null;
  }

  /// 여러 학생 ID의 이름을 Map으로 반환 (id -> name)
  Future<Map<String, String>> fetchNamesByIds(Iterable<String> ids) async {
    final list = ids.where((e) => e.trim().isNotEmpty).toSet().toList();
    if (list.isEmpty) return {};
    final res = await _client
        .from(SupabaseTables.students)
        .select('id, name')
        .inFilter('id', list);
    final map = <String, String>{};
    for (final row in (res as List)) {
      final m = Map<String, dynamic>.from(row);
      map[m['id'] as String] = m['name'] as String;
    }
    return map;
  }
}
