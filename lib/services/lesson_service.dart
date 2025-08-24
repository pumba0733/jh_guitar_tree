// lib/services/lesson_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/lesson.dart';
import '../supabase/supabase_tables.dart';

class LessonService {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<Lesson>> listByStudent(String studentId, {int limit = 50}) async {
    final res = await _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('student_id', studentId)
        .order('date', ascending: false)
        .limit(limit);
    return (res as List).map((e) => Lesson.fromMap(Map<String, dynamic>.from(e))).toList();
  }

  Future<List<Lesson>> listStudentFiltered({
    required String studentId,
    DateTime? from,
    DateTime? to,
    String? query,
    bool ascending = false,
    int limit = 200,
  }) async {
    final qb = _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('student_id', studentId);
    if (from != null) {
      qb.gte('date', from.toIso8601String());
    }
    if (to != null) {
      qb.lte('date', to.toIso8601String());
    }
    if (query != null && query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      qb.or('subject.ilike.%$q%,memo.ilike.%$q%,next_plan.ilike.%$q%');
    }
    qb.order('date', ascending: ascending);
    qb.limit(limit);
    final res = await qb;
    return (res as List).map((e) => Lesson.fromMap(Map<String, dynamic>.from(e))).toList();
  }

  Future<List<Lesson>> listTodayByTeacher(String teacherId) async {
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day).toIso8601String();
    final res = await _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('teacher_id', teacherId)
        .eq('date', day);
    return (res as List).map((e) => Lesson.fromMap(Map<String, dynamic>.from(e))).toList();
  }

  String _todayIsoDateOnly() {
    final now = DateTime.now();
    final dateOnly = DateTime(now.year, now.month, now.day);
    return dateOnly.toIso8601String();
  }

  Future<Lesson> upsertToday({
    required String studentId,
    String? teacherId,
    String? subject,
    String? memo,
    String? nextPlan,
    String? youtubeUrl,
  }) async {
    final dateStr = _todayIsoDateOnly();
    final payload = {
      'student_id': studentId,
      'date': dateStr,
      if (teacherId != null) 'teacher_id': teacherId,
      if (subject != null) 'subject': subject,
      if (memo != null) 'memo': memo,
      if (nextPlan != null) 'next_plan': nextPlan,
      if (youtubeUrl != null) 'youtube_url': youtubeUrl,
    };

    final res = await _client.from(SupabaseTables.lessons)
      .upsert(payload, onConflict: 'student_id,date')
      .select()
      .limit(1);
    final row = (res as List).first;
    return Lesson.fromMap(Map<String, dynamic>.from(row));
  }

  Future<Lesson> patchToday({
    required String studentId,
    String? subject,
    String? memo,
    String? nextPlan,
    String? youtubeUrl,
  }) async {
    final dateStr = _todayIsoDateOnly();
    final payload = <String, dynamic>{};
    if (subject != null) payload['subject'] = subject;
    if (memo != null) payload['memo'] = memo;
    if (nextPlan != null) payload['next_plan'] = nextPlan;
    if (youtubeUrl != null) payload['youtube_url'] = youtubeUrl;

    if (payload.isEmpty) {
      // Nothing to patch; return current row (upsert to ensure existence).
      return upsertToday(studentId: studentId);
    }

    final res = await _client
        .from(SupabaseTables.lessons)
        .update(payload)
        .eq('student_id', studentId)
        .eq('date', dateStr)
        .select()
        .limit(1);
    if (res is List && res.isNotEmpty) {
      return Lesson.fromMap(Map<String, dynamic>.from(res.first));
    } else {
      // If not exists, create with given payload.
      return upsertToday(
        studentId: studentId,
        subject: subject,
        memo: memo,
        nextPlan: nextPlan,
        youtubeUrl: youtubeUrl,
      );
    }
  }
}
