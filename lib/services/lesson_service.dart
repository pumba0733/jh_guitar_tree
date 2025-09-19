// lib/services/lesson_service.dart
// v1.46.0 | next_plan 완전 제거 (검색/생성/업서트 모두 제외)

import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/lesson.dart';
import '../supabase/supabase_tables.dart';
import '../../services/xsc_sync_service.dart';


class LessonService {
  final SupabaseClient _client = Supabase.instance.client;

  LessonService._internal();
  static final LessonService instance = LessonService._internal();
  factory LessonService() => instance;

  String _dateKey(DateTime d) => d.toIso8601String().split('T').first;

  // ========= 내부 유틸 =========

  String _basename(String s) {
    if (s.isEmpty) return 'file';
    final parts = s.split('/');
    return parts.isEmpty ? 'file' : (parts.last.isEmpty ? 'file' : parts.last);
  }

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

  List<Map<String, dynamic>>? _normalizeAttachments(dynamic v) {
    if (v == null) return null;
    final out = <Map<String, dynamic>>[];

    if (v is List) {
      for (final e in v) {
        if (e is Map) {
          final m = Map<String, dynamic>.from(e);
          final path = (m['path'] ?? '').toString();
          final url = (m['url'] ?? '').toString();
          final nameSrc = (m['name'] ?? '').toString();
          final name = nameSrc.isNotEmpty
              ? nameSrc
              : _basename(url.isNotEmpty ? url : path);
          final size = m['size'];
          out.add({
            'path': path,
            'url': url.isNotEmpty ? url : path,
            'name': name,
            if (size != null) 'size': size,
          });
        } else {
          final s = e.toString();
          out.add({'path': s, 'url': s, 'name': _basename(s)});
        }
      }
      return out;
    }

    final s = v.toString();
    return [
      {'path': s, 'url': s, 'name': _basename(s)},
    ];
  }

  // ========= 조회 =========

  Future<List<Map<String, dynamic>>> listByStudent(
    String studentId, {
    DateTime? from,
    DateTime? to,
    int limit = 100,
    int offset = 0,
    bool asc = false,
  }) async {
    return listByStudentPaged(
      studentId,
      from: from,
      to: to,
      query: null,
      limit: limit,
      offset: offset,
      asc: asc,
    );
  }

  Future<List<Map<String, dynamic>>> listByStudentPaged(
    String studentId, {
    DateTime? from,
    DateTime? to,
    String? query,
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

    if (query != null && query.trim().isNotEmpty) {
      final term = query.trim();
      q = q.or(
        // next_plan 필터 제거
        'subject.ilike.%$term%,memo.ilike.%$term%',
      );
    }

    final res = await q
        .order('date', ascending: asc)
        .range(offset, offset + limit - 1);

    return (res as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

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
        'p_sort': 'asc',
        'p_limit': 50,
        'p_offset': 0,
      },
    );

    return (res as List)
        .map((e) => Lesson.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

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
        // next_plan 필터 제거
        'subject.ilike.%$term%,memo.ilike.%$term%',
      );
    }

    final res = await q.order('date', ascending: false).limit(limit);
    return (res as List)
        .map((e) => Lesson.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>?> getById(String id) async {
    final res = await _client
        .from(SupabaseTables.lessons)
        .select()
        .eq('id', id)
        .maybeSingle();
    if (res == null) return null;
    return Map<String, dynamic>.from(res as Map);
  }

  Future<bool> exists(String id) async {
    final res = await _client
        .from(SupabaseTables.lessons)
        .select('id')
        .eq('id', id)
        .maybeSingle();
    return res != null;
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

  Future<Lesson> loadOrCreateLesson({
    required String studentId,
    String? teacherId,
    DateTime? date,
    String? subject,
    String? memo,
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
      // next_plan 제거
      'keywords': _normalizeKeywords(keywords) ?? <String>[],
      'attachments': <Map<String, dynamic>>[],
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
      // next_plan 제거
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

  Future<Lesson> upsertLesson({
    required String studentId,
    DateTime? date,
    String? subject,
    String? memo,
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
      if (youtubeUrl != null) 'youtube_url': youtubeUrl,
      if (keywords != null) 'keywords': _normalizeKeywords(keywords),
      if (attachments != null)
        'attachments': _normalizeAttachments(attachments),
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

  Future<Map<String, dynamic>> upsert(Map<String, dynamic> lesson) async {
    final payload = Map<String, dynamic>.from(lesson);

    // keywords/attachments 정규화
    if (payload.containsKey('keywords')) {
      payload['keywords'] = _normalizeKeywords(payload['keywords']);
    }
    if (payload.containsKey('attachments')) {
      payload['attachments'] = _normalizeAttachments(payload['attachments']);
    }

    // next_plan 키가 들어와도 무시되도록 제거 (후방 호환 안전장치)
    payload.remove('next_plan');

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

  // ========= 첨부 헬퍼 =========

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

  // ========= 삭제 =========

  /// 하드 삭제: 리스트 기반 RETURNING으로 PGRST116 회피하며 성공/실패 bool 반환
  Future<bool> deleteById(
    String id, {
    String? teacherId,
    String? studentId,
  }) async {
    try {
      var q = _client.from(SupabaseTables.lessons).delete().eq('id', id);
      if (teacherId != null && teacherId.isNotEmpty) {
        q = q.eq('teacher_id', teacherId);
      }
      if (studentId != null && studentId.isNotEmpty) {
        q = q.eq('student_id', studentId);
      }
      final List rows = await q.select('id') as List; // PGRST116 회피
      return rows.isNotEmpty;
    } on PostgrestException catch (e) {
      throw StateError('레슨 삭제 실패: ${e.message}');
    }
  }

  /// (선택) soft-delete: lessons 테이블에 is_deleted, deleted_at 컬럼이 있을 때만 사용
  Future<Map<String, dynamic>> softDeleteById(String id) async {
    final data = await _client
        .from(SupabaseTables.lessons)
        .update({
          'is_deleted': true,
          'deleted_at': DateTime.now().toIso8601String(),
        })
        .eq('id', id)
        .select()
        .maybeSingle();
    if (data == null) throw StateError('레슨 soft-delete 실패');
    return Map<String, dynamic>.from(data as Map);
  }
}
