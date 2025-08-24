// lib/services/summary_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/summary.dart';
import '../supabase/supabase_tables.dart';

class SummaryService {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<Summary>> listByStudent(String studentId, {int limit = 50}) async {
    final res = await _client
        .from(SupabaseTables.summaries)
        .select()
        .eq('student_id', studentId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (res as List).map((e) => Summary.fromMap(Map<String, dynamic>.from(e))).toList();
  }

  /// 요약 생성 요청 (현재는 LLM 미연동 → placeholder 텍스트 저장)
  Future<String> createSummaryForSelectedLessons({
    required String studentId,
    String? teacherId,
    required String type, // '기간별' | '키워드'
    DateTime? periodStart,
    DateTime? periodEnd,
    List<String> keywords = const [],
    required List<String> selectedLessonIds,
  }) async {
    final res = await _client
        .from(SupabaseTables.summaries)
        .insert({
          'student_id': studentId,
          if (teacherId != null) 'teacher_id': teacherId,
          'type': type,
          'period_start': periodStart?.toIso8601String(),
          'period_end': periodEnd?.toIso8601String(),
          'keywords': keywords,
          'selected_lesson_ids': selectedLessonIds,
          'result_student': '요약(학생용): LLM 연결 전 시범 텍스트입니다.',
          'result_parent': '요약(보호자용): LLM 연결 전 시범 텍스트입니다.',
          'result_blog': '요약(블로그용): LLM 연결 전 시범 텍스트입니다.',
          'result_teacher': '요약(강사용): LLM 연결 전 시범 텍스트입니다.',
          'visible_to': ['teacher','admin'],
        })
        .select('id')
        .limit(1);
    final row = (res as List).first as Map<String, dynamic>;
    return '${row['id']}';
  }

  Future<Summary?> getById(String id) async {
    final res = await _client
        .from(SupabaseTables.summaries)
        .select()
        .eq('id', id)
        .limit(1);
    if (res is List && res.isNotEmpty) {
      return Summary.fromMap(Map<String, dynamic>.from(res.first));
    }
    return null;
  }
}
