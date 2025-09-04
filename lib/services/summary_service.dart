// lib/services/summary_service.dart
// v1.21.3 | 최신 요약 조회 기능 추가 (getLatestByStudent)
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/summary.dart';
import 'llm_service.dart';
import 'retry_queue_service.dart';

class SummaryService {
  final SupabaseClient _supabase;
  SummaryService._internal([SupabaseClient? client])
    : _supabase = client ?? Supabase.instance.client;
  static final SummaryService instance = SummaryService._internal();
  factory SummaryService() => instance;
  SummaryService.withClient(SupabaseClient client) : _supabase = client;

  static const String _table = 'summaries';

  Future<Summary?> getById(String id) async {
    final data = await _supabase
        .from(_table)
        .select()
        .eq('id', id)
        .maybeSingle();
    return data == null
        ? null
        : Summary.fromMap(Map<String, dynamic>.from(data as Map));
  }

  Future<List<Summary>> listByStudent(
    String studentId, {
    int limit = 100,
  }) async {
    final data = await _supabase
        .from(_table)
        .select()
        .eq('student_id', studentId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (data as List)
        .map((e) => Summary.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// ✅ 학생별 최신 요약 1건만 가져오기
  Future<Summary?> getLatestByStudent(String studentId) async {
    final data = await _supabase
        .from(_table)
        .select()
        .eq('student_id', studentId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (data == null) return null;
    return Summary.fromMap(Map<String, dynamic>.from(data as Map));
  }

  /// (화면 호환용) 기존 명칭
  Future<Summary> createSummaryForSelectedLessons({
    required String studentId,
    String? teacherId,
    required String type, // '기간별' | '키워드'
    DateTime? periodStart,
    DateTime? periodEnd,
    List<String>? selectedLessonIds,
    List<String>? keywords,
  }) {
    return generateAndSaveSummary(
      studentId: studentId,
      teacherId: teacherId,
      type: type,
      periodStart: periodStart,
      periodEnd: periodEnd,
      selectedLessonIds: selectedLessonIds,
      keywords: keywords,
    );
  }

  /// LLM 호출 → 4종 요약 생성 → summaries upsert
  Future<Summary> generateAndSaveSummary({
    required String studentId,
    String? teacherId,
    required String type,
    DateTime? periodStart,
    DateTime? periodEnd,
    List<String>? selectedLessonIds,
    List<String>? keywords,
  }) async {
    // 1) 컨텍스트 로딩
    final student = await _supabase
        .from('students')
        .select()
        .eq('id', studentId)
        .maybeSingle();

    final lessons = (selectedLessonIds == null || selectedLessonIds.isEmpty)
        ? await _supabase
              .from('lessons')
              .select()
              .eq('student_id', studentId)
              .order('date', ascending: true)
        : await _supabase
              .from('lessons')
              .select()
              .inFilter('id', selectedLessonIds);

    final studentInfo = {
      'id': studentId,
      'name': student?['name'],
      'gender': student?['gender'],
      'is_adult': student?['is_adult'],
      'school_name': student?['school_name'],
      'grade': student?['grade'],
      'start_date': student?['start_date'],
      'instrument': student?['instrument'],
    };

    // 2) LLM 호출
    final llm = LlmService();
    final result = await llm.generateFourSummaries(
      studentInfo: Map<String, dynamic>.from(studentInfo),
      lessons: (lessons as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      condition: {
        'type': type,
        if (periodStart != null)
          'period_start': periodStart.toIso8601String().split('T').first,
        if (periodEnd != null)
          'period_end': periodEnd.toIso8601String().split('T').first,
        if (keywords != null) 'keywords': keywords,
      },
    );

    final row = {
      'student_id': studentId,
      if (teacherId != null) 'teacher_id': teacherId,
      'type': type,
      if (periodStart != null)
        'period_start': periodStart.toIso8601String().split('T').first,
      if (periodEnd != null)
        'period_end': periodEnd.toIso8601String().split('T').first,
      'selected_lesson_ids': (selectedLessonIds ?? const []).toList(),
      'keywords': (keywords ?? const []).toList(),
      'student_info': studentInfo,
      'result_student': result['result_student'],
      'result_parent': result['result_parent'],
      'result_blog': result['result_blog'],
      'result_teacher': result['result_teacher'],
    };

    // 3) 저장
    try {
      final saved = await _supabase
          .from(_table)
          .upsert(row)
          .select()
          .maybeSingle();
      if (saved == null) throw StateError('요약 저장 실패');
      return Summary.fromMap(Map<String, dynamic>.from(saved as Map));
    } catch (_) {
      await RetryQueueService().enqueue(
        RetryTask(
          id: 'summary:$studentId:${DateTime.now().millisecondsSinceEpoch}',
          kind: 'summary_upsert',
          payload: {'row': row},
        ),
      );

      // ⬇️ Fallback 레코드에 최소 필드 보강
      final nowIso = DateTime.now().toIso8601String();
      final local = {
        'id': 'local_${DateTime.now().millisecondsSinceEpoch}', // 임시 ID
        'created_at': nowIso,
        ...row,
      };
      return Summary.fromMap(Map<String, dynamic>.from(local));
    }
  }

  Future<Summary?> updateSummary({
    required String id,
    String? resultStudent,
    String? resultParent,
    String? resultBlog,
    String? resultTeacher,
  }) async {
    final upd = {
      if (resultStudent != null) 'result_student': resultStudent,
      if (resultParent != null) 'result_parent': resultParent,
      if (resultBlog != null) 'result_blog': resultBlog,
      if (resultTeacher != null) 'result_teacher': resultTeacher,
    };
    final data = await _supabase
        .from(_table)
        .update(upd)
        .eq('id', id)
        .select()
        .maybeSingle();
    if (data == null) return null;
    return Summary.fromMap(Map<String, dynamic>.from(data as Map));
  }
}
