// lib/services/log_service.dart
import 'dart:developer' as dev;
import '../supabase/supabase_tables.dart';
import 'supabase_service.dart';

class LogService {
  LogService._();
  static final _sb = SupabaseService.client;

  // 쓰기
  static Future<void> insertLog({
    required String type,
    Map<String, dynamic>? payload,
    String? userId,
  }) async {
    try {
      await _sb.from(SupabaseTables.logs).insert({
        'type': type,
        if (userId != null) 'user_id': userId,
        if (payload != null) 'payload': payload,
      });
    } catch (e) {
      dev.log('Log insert failed: $e', name: 'LogService');
    }
  }

  // 일일 집계 뷰
  static Future<List<Map<String, dynamic>>> fetchDailyCounts({int days = 60}) async {
    final res = await _sb
        .from('log_daily_counts')
        .select()
        .order('day', ascending: false)
        .limit(days);
    return (res as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // 최근 오류 (rpc: list_recent_errors)
  static Future<List<Map<String, dynamic>>> fetchRecentErrors({int limit = 50}) async {
    final res = await _sb.rpc('list_recent_errors', params: {'p_limit': limit});
    return (res as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }
}
