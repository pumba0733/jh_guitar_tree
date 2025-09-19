// lib/services/lesson_links_service.dart
// v1.57.2 | 오늘 레슨 ID 확정(ensure 반환값 우선) + 직접 INSERT 후 RPC 폴백
// - FIX: getTodayLessonId()가 ensure로 받은 ID를 바로 사용 (UTC/로컬 차단)
// - FIX: sendNodeToTodayLessonId 중복 정의 제거
// - VIEW 우선, 실테이블 폴백 로직 유지

import 'dart:async';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/resource.dart';
import '../supabase/supabase_tables.dart';

class LessonLinksService {
  final SupabaseClient _c = Supabase.instance.client;

  Future<T> _retry<T>(
    Future<T> Function() task, {
    int maxAttempts = 3,
    Duration baseDelay = const Duration(milliseconds: 250),
    Duration timeout = const Duration(seconds: 15),
    bool Function(Object e)? shouldRetry,
  }) async {
    int attempt = 0;
    Object? lastError;
    while (attempt < maxAttempts) {
      attempt++;
      try {
        return await task().timeout(timeout);
      } on TimeoutException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
        final s = e.toString();
        final retry =
            (shouldRetry?.call(e) ?? false) ||
            e is SocketException ||
            e is HttpException ||
            e is TimeoutException ||
            s.contains('ENETUNREACH') ||
            s.contains('Connection closed') ||
            s.contains('temporarily unavailable') ||
            s.contains('503') ||
            s.contains('502') ||
            s.contains('429');
        if (!retry || attempt >= maxAttempts) rethrow;
      }
      if (attempt < maxAttempts) {
        final wait = baseDelay * (1 << (attempt - 1));
        await Future.delayed(wait);
      }
    }
    throw lastError ?? StateError('네트워크 오류');
  }

  Future<String?> _rpcString(String fn, Map<String, dynamic> params) async {
    try {
      final res = await _retry(() => _c.rpc(fn, params: params));
      if (res == null) return null;
      return res.toString();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _findTodayLessonId(String studentId) async {
    try {
      // 로컬(앱) 기준 "오늘" 날짜 문자열
      final today = DateTime.now();
      final yyyy = today.year.toString().padLeft(4, '0');
      final mm = today.month.toString().padLeft(2, '0');
      final dd = today.day.toString().padLeft(2, '0');
      final d = '$yyyy-$mm-$dd';

      final rows = await _retry(
        () => _c
            .from(SupabaseTables.lessons)
            .select('id')
            .eq('student_id', studentId)
            .eq('date', d)
            .limit(1),
      );
      final list = (rows as List);
      if (list.isEmpty) return null;
      return (list.first['id'] ?? '').toString();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _ensureTodayLessonId(String studentId) async {
    // 서버 RPC (UTC current_date)
    return _rpcString('ensure_today_lesson', {'p_student_id': studentId});
  }

  Future<String?> getTodayLessonId(
    String studentId, {
    bool ensure = false,
  }) async {
    // 1) 먼저 로컬 날짜로 탐색
    String? id = await _findTodayLessonId(studentId);

    // 2) 없고 ensure면 서버에서 생성 → 서버가 돌려준 id를 "우선" 사용
    if (id == null && ensure) {
      final ensuredId = await _ensureTodayLessonId(studentId);
      id = ensuredId ?? await _findTodayLessonId(studentId);
    }
    return id;
  }

  /// 내부 유틸: lesson_links/lesson_resource_links에 직접 INSERT (리소스)
  Future<String?> _insertResourceLinkDirect({
    required String lessonId,
    required ResourceFile resource,
  }) async {
    Future<String?> _ins(String table) async {
      final payload = <String, dynamic>{
        'lesson_id': lessonId,
        'kind': 'resource',
        'resource_bucket': resource.storageBucket,
        'resource_path': resource.storagePath,
        'resource_filename': resource.filename,
        if ((resource.title ?? '').toString().isNotEmpty)
          'resource_title': resource.title,
      };
      final row = await _retry(
        () => _c.from(table).insert(payload).select('id').single(),
      );
      final id = (row is Map && row['id'] != null)
          ? row['id'].toString()
          : null;
      return id;
    }

    try {
      try {
        final viaView = await _ins(
          SupabaseTables.lessonLinks,
        ); // 'lesson_links' 뷰
        if (viaView != null) return viaView;
      } catch (_) {
        // 뷰 경로 실패 → 실테이블 폴백
      }
      return await _ins(SupabaseTables.lessonResourceLinks); // 실테이블
    } catch (_) {
      return null;
    }
  }

  /// 내부 유틸: node 링크 직접 INSERT (노드)
  Future<String?> _insertNodeLinkDirect({
    required String lessonId,
    required String nodeId,
  }) async {
    Future<String?> _ins(String table) async {
      final payload = <String, dynamic>{
        'lesson_id': lessonId,
        'kind': 'node',
        'curriculum_node_id': nodeId,
      };
      final row = await _retry(
        () => _c.from(table).insert(payload).select('id').single(),
      );
      final id = (row is Map && row['id'] != null)
          ? row['id'].toString()
          : null;
      return id;
    }

    try {
      try {
        final viaView = await _ins(SupabaseTables.lessonLinks);
        if (viaView != null) return viaView;
      } catch (_) {}
      return await _ins(SupabaseTables.lessonResourceLinks);
    } catch (_) {
      return null;
    }
  }

  /// 삭제: VIEW 우선 → 실테이블 폴백
  Future<bool> deleteById(
    String id, {
    String? studentId,
    String? teacherId,
  }) async {
    try {
      await _retry(
        () => _c.from(SupabaseTables.lessonLinks).delete().eq('id', id),
      );
      return true;
    } catch (_) {}
    try {
      await _retry(
        () => _c.from(SupabaseTables.lessonResourceLinks).delete().eq('id', id),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  // === 링크 생성 (노드) ===
  Future<String?> sendNodeToTodayLessonId({
    required String studentId,
    required String nodeId,
  }) async {
    // 1) 오늘 레슨 ID 확보(+ensure)
    final lessonId = await getTodayLessonId(studentId, ensure: true);

    // 2) 직접 INSERT 우선
    if (lessonId != null) {
      final direct = await _insertNodeLinkDirect(
        lessonId: lessonId,
        nodeId: nodeId,
      );
      if (direct != null) return direct;
    }

    // 3) RPC 폴백
    return _rpcString('link_node_to_today_lesson', {
      'p_student_id': studentId,
      'p_node_id': nodeId,
    });
  }

  Future<bool> sendNodeToTodayLesson({
    required String studentId,
    required String nodeId,
  }) async {
    final id = await sendNodeToTodayLessonId(
      studentId: studentId,
      nodeId: nodeId,
    );
    return id != null;
  }

  // === 링크 생성 (리소스) ===
  Future<String?> sendResourceToTodayLessonId({
    required String studentId,
    required ResourceFile resource,
  }) async {
    final lessonId = await getTodayLessonId(studentId, ensure: true);

    if (lessonId != null) {
      final direct = await _insertResourceLinkDirect(
        lessonId: lessonId,
        resource: resource,
      );
      if (direct != null) return direct;
    }

    return _rpcString('link_resource_to_today_lesson', {
      'p_student_id': studentId,
      'p_bucket': resource.storageBucket,
      'p_path': resource.storagePath,
      'p_filename': resource.filename,
      'p_title': resource.title,
    });
  }

  Future<bool> sendResourceToTodayLesson({
    required String studentId,
    required ResourceFile resource,
  }) async {
    final id = await sendResourceToTodayLessonId(
      studentId: studentId,
      resource: resource,
    );
    return id != null;
  }

  // === 조회 ===
  Future<List<Map<String, dynamic>>> listByLesson(String lessonId) async {
    Future<List<Map<String, dynamic>>> _selectFrom(String table) async {
      final rows = await _retry(
        () => _c
            .from(table)
            .select()
            .eq('lesson_id', lessonId)
            .order('created_at', ascending: false),
      );
      return (rows as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
    }

    try {
      final viaView = await _selectFrom(SupabaseTables.lessonLinks); // VIEW
      if (viaView.isNotEmpty) return viaView;
      final viaTable = await _selectFrom(
        SupabaseTables.lessonResourceLinks,
      ); // TABLE
      return viaTable;
    } catch (_) {
      try {
        return await _selectFrom(SupabaseTables.lessonResourceLinks);
      } catch (_) {
        return const [];
      }
    }
  }

  Future<List<Map<String, dynamic>>> listTodayByStudent(
    String studentId, {
    bool ensure = false, // 사용처에서 ensure: true 권장
  }) async {
    final lessonId = await getTodayLessonId(studentId, ensure: ensure);
    if (lessonId == null) return const [];
    return listByLesson(lessonId);
  }

  Future<void> touchXscUpdatedAt({
    required String studentId,
    required String mp3Hash,
  }) async {
    try {
      await _c.rpc(
        'touch_xsc_meta_for_student_hash',
        params: {'p_student_id': studentId, 'p_mp3_hash': mp3Hash},
      );
    } catch (_) {}
  }
}
