// lib/services/lesson_service.dart
// v1.25 | 안전 보강 + 헬퍼 확장
// - 기존 v1.24 시그니처 100% 호환 유지
// - insert 경로: onConflict(student_id,date) 유지
// - update 경로: DB 트리거(updated_at) 의존 (클라이언트에서 updated_at 세팅 불필요)
// - attachments/keywords 정규화 보강
//
// 참고: lessons 테이블 스키마
//   attachments: jsonb  (표준 형태: [{path, url, name, size?}, ...])
//   keywords:    jsonb  (문자열 배열)

import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/lesson.dart';
import '../supabase/supabase_tables.dart';

class LessonService {
  final SupabaseClient _client = Supabase.instance.client;

  LessonService._internal();
  static final LessonService instance = LessonService._internal();
  factory LessonService() => instance;

  String _dateKey(DateTime d) => d.toIso8601String().split('T').first;

  // ========= 내부 유틸 =========

  /// keywords가 혼합타입(List<dynamic>)로 넘어와도 문자열 배열로 정규화
  List<String>? _normalizeKeywords(dynamic v) {
    if (v == null) return null;
    if (v is List) {
      final out = <String>[];
      for (final e in v) {
        final s = (e == null) ? '' : e.toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
      return out;
    }
    return null;
  }

  /// attachments를 [{path,url,name,size?}, ...]로 정규화
  /// - 문자열(single URL/경로) 또는 혼합타입이 와도 최소 키를 보장
  List<Map<String, dynamic>>? _normalizeAttachments(dynamic v) {
    if (v == null) return null;
    final out = <Map<String, dynamic>>[];
    if (v is List) {
      for (final e in v) {
        if (e is Map) {
          final m = Map<String, dynamic>.from(e);
          final path = (m['path'] ?? '').toString();
          final url = (m['url'] ?? '').toString();
          final name = (m['name'] ?? (path.isNotEmpty ? path : url)).toString();
          final size = m['size'];
          out.add({
            'path': path,
            'url': url.isNotEmpty ? url : path,
            'name': name,
            if (size != null) 'size': size,
          });
        } else {
          final s = e.toString();
          out.add({
            'path': s,
            'url': s,
            'name': s.split('/').isNotEmpty ? s.split('/').last : 'file',
          });
        }
      }
      return out;
    }
    // 단일 값 처리
    final s = v.toString();
    return [
      {
        'path': s,
        'url': s,
        'name': s.split('/').isNotEmpty ? s.split('/').last : 'file',
      },
    ];
  }

  // ========= 조회 =========

  /// 화면용: 학생별 레슨(Map) 리스트
  Future<List<Map<String, dynamic>>> listByStudent(
    String studentId, {
    DateTime? from,
    DateTime? to,
    int limit = 100,
    int offset = 0,
    bool asc = false,
  }) async {
    dynamic q = _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('student_id', studentId);

    if (from != null) q = q.gte('date', _dateKey(from));
    if (to != null) q = q.lte('date', _dateKey(to));

    final res = await q
        .order('date', ascending: asc)
        .range(offset, offset + limit - 1);

    return (res as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// 기존 호환: 모델 리스트
  Future<List<Lesson>> listByStudentAsModel(
    String studentId, {
    int limit = 50,
  }) async {
    final res = await _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('student_id', studentId)
        .order('date', ascending: false)
        .limit(limit);

    return (res as List)
        .map((e) => Lesson.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 강사 기준 오늘 수업 목록 (당일 00:00 ~ +1일 00:00, 날짜 오름차순)
  Future<List<Lesson>> listTodayByTeacher(String teacherId) async {
    final today = DateTime.now();
    final from = DateTime(today.year, today.month, today.day);
    final to = from.add(const Duration(days: 1));

    final res = await _client.rpc(
      'list_lessons_by_teacher_filtered',
      params: {
        'p_teacher_id': teacherId,
        'p_from': _dateKey(from),
        'p_to': _dateKey(to),
        'p_query': null,
        'p_sort': 'asc', // 오름차순
        'p_limit': 50,
        'p_offset': 0,
      },
    );

    return (res as List)
        .map((e) => Lesson.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 학생 히스토리 검색 필터
  Future<List<Lesson>> listStudentFiltered(
    String studentId, {
    String? query,
    int limit = 50,
  }) async {
    dynamic q = _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('student_id', studentId);

    if (query != null && query.trim().isNotEmpty) {
      final term = query.trim();
      q = q.or(
        'subject.ilike.%$term%,memo.ilike.%$term%,next_plan.ilike.%$term%',
      );
    }

    final res = await q.order('date', ascending: false).limit(limit);
    return (res as List)
        .map((e) => Lesson.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 단건 조회(id)
  Future<Map<String, dynamic>?> getById(String id) async {
    final res = await _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('id', id)
        .maybeSingle();
    if (res == null) return null;
    return Map<String, dynamic>.from(res as Map);
  }

  Future<Map<String, dynamic>?> _getRowByStudentAndDate(
    String studentId,
    DateTime date,
  ) async {
    final res = await _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('student_id', studentId)
        .eq('date', _dateKey(date))
        .maybeSingle();
    return (res == null) ? null : Map<String, dynamic>.from(res as Map);
  }

  // ========= 생성/갱신 =========

  /// 오늘 레슨 불러오기/생성 (모델 반환)
  Future<Lesson> loadOrCreateLesson({
    required String studentId,
    String? teacherId,
    DateTime? date,
    String? subject,
    String? memo,
    String? nextPlan,
    String? youtubeUrl,
    List<String>? keywords,
  }) async {
    final theDate = date ?? DateTime.now();
    final exists = await _getRowByStudentAndDate(studentId, theDate);
    if (exists != null) return Lesson.fromMap(exists);

    final insert = {
      'student_id': studentId,
      if (teacherId != null && teacherId.isNotEmpty) 'teacher_id': teacherId,
      'date': _dateKey(theDate),
      'subject': subject ?? '',
      'memo': memo ?? '',
      'next_plan': nextPlan ?? '',
      'keywords': _normalizeKeywords(keywords) ?? <String>[],
      'attachments': <Map<String, dynamic>>[], // 기본값 명시
      'youtube_url': youtubeUrl ?? '',
    };

    final data = await _client
        .from(SupabaseTables.lessons)
        .insert(insert)
        .select()
        .maybeSingle();

    if (data == null) throw StateError('레슨 생성 실패');
    return Lesson.fromMap(Map<String, dynamic>.from(data as Map));
  }

  /// 오늘 row 보장(Map 버전)
  Future<Map<String, dynamic>> ensureTodayRow({
    required String studentId,
    String? teacherId,
  }) async {
    final today = DateTime.now();
    final exists = await _getRowByStudentAndDate(studentId, today);
    if (exists != null) return exists;

    final insert = {
      'student_id': studentId,
      if (teacherId != null && teacherId.isNotEmpty) 'teacher_id': teacherId,
      'date': _dateKey(today),
      'subject': '',
      'memo': '',
      'next_plan': '',
      'keywords': <String>[],
      'attachments': <Map<String, dynamic>>[],
      'youtube_url': '',
    };

    final data = await _client
        .from(SupabaseTables.lessons)
        .insert(insert)
        .select()
        .maybeSingle();
    if (data == null) throw StateError('레슨 생성 실패');
    return Map<String, dynamic>.from(data as Map);
  }

  /// studentId+date 기준 upsert (모델 반환)
  Future<Lesson> upsertLesson({
    required String studentId,
    DateTime? date,
    String? subject,
    String? memo,
    String? nextPlan,
    String? youtubeUrl,
    List<String>? keywords,
    List<Map<String, dynamic>>? attachments,
    String? teacherId,
  }) async {
    final theDate = date ?? DateTime.now();
    final exists = await _getRowByStudentAndDate(studentId, theDate);
    final patch = <String, dynamic>{
      if (teacherId != null && teacherId.isNotEmpty) 'teacher_id': teacherId,
      if (subject != null) 'subject': subject,
      if (memo != null) 'memo': memo,
      if (nextPlan != null) 'next_plan': nextPlan,
      if (youtubeUrl != null) 'youtube_url': youtubeUrl,
      if (keywords != null) 'keywords': _normalizeKeywords(keywords),
      if (attachments != null)
        'attachments': _normalizeAttachments(attachments),
      // updated_at은 트리거에서 처리
    };

    Map<String, dynamic>? data;
    if (exists == null) {
      final insert = {
        'student_id': studentId,
        'date': _dateKey(theDate),
        ...patch,
      };
      data = await _client
          .from(SupabaseTables.lessons)
          .upsert(insert, onConflict: 'student_id,date')
          .select()
          .maybeSingle();
    } else {
      data = await _client
          .from(SupabaseTables.lessons)
          .update(patch)
          .eq('student_id', studentId)
          .eq('date', _dateKey(theDate))
          .select()
          .maybeSingle();
    }

    if (data == null) throw StateError('레슨 upsert 실패');
    return Lesson.fromMap(Map<String, dynamic>.from(data as Map));
  }

  /// Map 기반 upsert
  /// - id가 있으면 update(id)
  /// - 새 row일 때만 onConflict(student_id,date)
  Future<Map<String, dynamic>> upsert(Map<String, dynamic> lesson) async {
    final payload = Map<String, dynamic>.from(lesson);

    // 정규화
    if (payload.containsKey('keywords')) {
      payload['keywords'] = _normalizeKeywords(payload['keywords']);
    }
    if (payload.containsKey('attachments')) {
      payload['attachments'] = _normalizeAttachments(payload['attachments']);
    }

    // update(id) 경로
    final id = payload.remove('id');
    if (id != null) {
      final data = await _client
          .from(SupabaseTables.lessons)
          .update(payload)
          .eq('id', id)
          .select()
          .maybeSingle();
      if (data == null) throw StateError('레슨 upsert 실패');
      return Map<String, dynamic>.from(data as Map);
    }

    // insert/upsert 경로 — onConflict(student_id,date) 보장
    if (!payload.containsKey('student_id')) {
      throw ArgumentError('upsert: student_id가 필요합니다');
    }
    if (!payload.containsKey('date') ||
        (payload['date'] as String?)?.isNotEmpty != true) {
      payload['date'] = _dateKey(DateTime.now());
    }

    final data = await _client
        .from(SupabaseTables.lessons)
        .upsert(payload, onConflict: 'student_id,date')
        .select()
        .maybeSingle();
    if (data == null) throw StateError('레슨 upsert 실패');
    return Map<String, dynamic>.from(data as Map);
  }

  /// 오늘자 upsert (모델 반환)
  Future<Lesson> upsertToday({
    required String studentId,
    String? subject,
    String? memo,
    String? nextPlan,
    String? youtubeUrl,
    List<String>? keywords,
    List<Map<String, dynamic>>? attachments,
    String? teacherId,
  }) {
    return upsertLesson(
      studentId: studentId,
      date: DateTime.now(),
      subject: subject,
      memo: memo,
      nextPlan: nextPlan,
      youtubeUrl: youtubeUrl,
      keywords: keywords,
      attachments: attachments,
      teacherId: teacherId,
    );
  }

  // ========= 첨부 헬퍼 =========

  /// attachments 전체 치환(서버 기준)
  Future<Map<String, dynamic>> setAttachments({
    required String id,
    required List<Map<String, dynamic>> attachments,
  }) async {
    final data = await _client
        .from(SupabaseTables.lessons)
        .update({'attachments': _normalizeAttachments(attachments)})
        .eq('id', id)
        .select()
        .maybeSingle();
    if (data == null) throw StateError('첨부 저장 실패');
    return Map<String, dynamic>.from(data as Map);
  }

  /// 단건 추가(클라이언트 병합)
  Future<Map<String, dynamic>> addAttachment({
    required String id,
    required Map<String, dynamic> attachment,
  }) async {
    final cur = await getById(id);
    final list = <Map<String, dynamic>>[
      ...(cur?['attachments'] is List
          ? (cur!['attachments'] as List).map<Map<String, dynamic>>(
              (e) => Map<String, dynamic>.from(e as Map),
            )
          : const <Map<String, dynamic>>[]),
      attachment,
    ];
    return setAttachments(id: id, attachments: list);
  }

  /// 조건 제거(클라이언트 병합)
  Future<Map<String, dynamic>> removeAttachment({
    required String id,
    required bool Function(Map<String, dynamic>) test,
  }) async {
    final cur = await getById(id);
    final list = <Map<String, dynamic>>[
      ...(cur?['attachments'] is List
          ? (cur!['attachments'] as List).map<Map<String, dynamic>>(
              (e) => Map<String, dynamic>.from(e as Map),
            )
          : const <Map<String, dynamic>>[]),
    ]..removeWhere(test);
    return setAttachments(id: id, attachments: list);
  }
}
