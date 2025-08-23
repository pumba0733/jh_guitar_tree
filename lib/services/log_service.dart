// v1.05 | 로그 단일 진입점
import 'dart:developer' as dev;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';
import 'supabase_service.dart';

class LogService {
  LogService._();
  static final _sb = SupabaseService.client;

  static Future<void> insertLog({
    required String type,
    Map<String, dynamic>? payload,
    String? userId, // 학생 간편 로그인 전에도 null로 기록 가능
  }) async {
    try {
      await _sb.from(SupabaseTables.logs).insert({
        'type': type,
        'user_id': userId,
        'payload': payload ?? {},
      });
    } catch (e, st) {
      dev.log('Log insert failed: $e', stackTrace: st, name: 'LogService');
    }
  }
}
