// lib/services/lesson_service.dart
// v1.06 | 레슨 읽기/저장 + 실시간 스트림
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/lesson.dart';
import '../supabase/supabase_tables.dart';

class LessonService {
  final SupabaseClient _client = Supabase.instance.client;

  /// 특정 학생의 날짜별 레슨 리스트
  Future<List<Lesson>> listByStudent(String studentId, {int limit = 50}) async {
    final res = await _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('student_id', studentId)
        .order('date', ascending: false)
        .limit(limit);
    return (res as List)
        .map((e) => Lesson.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 오늘 레슨 upsert (있으면 업데이트, 없으면 생성)
  Future<Lesson> upsertToday({
    required String studentId,
    String? teacherId,
    String? subject,
    String? memo,
    String? nextPlan,
    String? youtubeUrl,
  }) async {
    final today = DateTime.now();
    final dateStr = today.toIso8601String().substring(0, 10);
    final payload = {
      'student_id': studentId,
      'teacher_id': teacherId,
      'date': dateStr,
      'subject': subject,
      'memo': memo,
      'next_plan': nextPlan,
      'youtube_url': youtubeUrl,
    };

    final res = await _client
        .from(SupabaseTables.lessons)
        .upsert(payload, onConflict: 'student_id,date')
        .select()
        .maybeSingle();

    if (res == null) {
      // 일부 버전에서 maybeSingle가 null을 반환할 수 있어 재조회
      final q = await _client
          .from(SupabaseTables.lessons)
          .select()
          .eq('student_id', studentId)
          .eq('date', dateStr)
          .single();
      return Lesson.fromMap(Map<String, dynamic>.from(q));
    }

    return Lesson.fromMap(Map<String, dynamic>.from(res));
  }

  /// 필드 부분 업데이트 (id가 아닌 student_id+date 키 기준)
  Future<Lesson> patchToday(
    String studentId,
    Map<String, dynamic> fields,
  ) async {
    final dateStr = DateTime.now().toIso8601String().substring(0, 10);
    final res = await _client
        .from(SupabaseTables.lessons)
        .update(fields)
        .match({'student_id': studentId, 'date': dateStr})
        .select()
        .single();
    return Lesson.fromMap(Map<String, dynamic>.from(res));
  }

  /// 실시간 스트림 (lessons 테이블)
  Stream<List<Lesson>> streamByStudent(String studentId) {
    return _client
        .from(SupabaseTables.lessons)
        .stream(primaryKey: ['id'])
        .eq('student_id', studentId)
        .order('date', ascending: false)
        .map(
          (rows) => rows
              .map((e) => Lesson.fromMap(Map<String, dynamic>.from(e)))
              .toList(),
        );
  }
}
