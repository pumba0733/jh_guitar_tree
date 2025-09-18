// lib/services/lesson_links_service.dart
// v1.57.1 | 오늘 레슨 ID 확정 후 직접 INSERT로 링크 생성 + RPC 폴백
// - FIX: UTC/로컬 날짜 불일치로 링크가 "다른 레슨"에 들어가 목록에 안 뜨는 문제 해결
// - listByLesson(): 뷰→테이블 폴백 유지
// - delete 로직/기타 기존 기능 유지

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
    // 서버 RPC (UTC current_date) — 폴백용
    return _rpcString('ensure_today_lesson', {'p_student_id': studentId});
  }

  Future<String?> getTodayLessonId(
    String studentId, {
    bool ensure = false,
  }) async {
    // 1) 먼저 로컬 날짜로 탐색
    String? id = await _findTodayLessonId(studentId);
    // 2) 없고 ensure면 서버에서 생성(UTC) → 다시 로컬 날짜로 한 번 더 조회
    if (id == null && ensure) {
      await _ensureTodayLessonId(studentId);
      id = await _findTodayLessonId(studentId);
    }
    return id;
  }

  /// 내부 유틸: lesson_links/lesson_resource_links에 직접 INSERT
  Future<String?> _insertResourceLinkDirect({
    required String lessonId,
    required ResourceFile resource,
  }) async {
    // 뷰가 있으면 뷰로(룰 통해 실테이블 저장), 없으면 실테이블로
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

  /// 내부 유틸: node 링크 직접 INSERT (노드도 동일 전략)
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

  /// 삭제: 보안 RPC 우선, 실패 시 DELETE 폴백
  Future<bool> deleteById(
    String id, {
    String? studentId,
    String? teacherId,
  }) async {
    // 1) RPC 우선
    try {
      if ((studentId ?? '').isNotEmpty) {
        final res = await _retry(
          () => _c.rpc(
            'delete_lesson_link',
            params: {'p_link_id': id, 'p_student_id': studentId},
          ),
        );
        if (res == true || res == 'true') return true;
      }
    } catch (_) {
      // RPC 실패 → 폴백 시도
    }

    // 2) 폴백: 직접 DELETE (RLS 허용 범위에서만 성공)
    try {
      final q = _c.from(SupabaseTables.lessonLinks).delete().eq('id', id);
      if (studentId != null && studentId.trim().isNotEmpty) {
        q.eq('student_id', studentId.trim()); // 뷰에는 컬럼이 없을 수도 있어 무시될 수 있음
      } else if (teacherId != null && teacherId.trim().isNotEmpty) {
        q.eq('teacher_id', teacherId.trim()); // 동일
      }
      await _retry(() => q);
      return true;
    } catch (_) {
      try {
        await _retry(
          () =>
              _c.from(SupabaseTables.lessonResourceLinks).delete().eq('id', id),
        );
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  // === 링크 생성 (노드) ===
  Future<String?> sendNodeToTodayLessonId({
    required String studentId,
    required String nodeId,
  }) async {
    // 오늘 레슨 ID를 먼저 확정(로컬 날짜 기준으로 보장)
    final lessonId = await getTodayLessonId(studentId, ensure: true);
    if (lessonId == null) return null;

    // 1) 직접 INSERT 우선
    final direct = await _insertNodeLinkDirect(
      lessonId: lessonId,
      nodeId: nodeId,
    );
    if (direct != null) return direct;

    // 2) 폴백: RPC
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
    // 오늘 레슨 ID를 먼저 확정(로컬 날짜 기준으로 보장)
    final lessonId = await getTodayLessonId(studentId, ensure: true);
    if (lessonId == null) return null;

    // 1) 직접 INSERT 우선
    final direct = await _insertResourceLinkDirect(
      lessonId: lessonId,
      resource: resource,
    );
    if (direct != null) return direct;

    // 2) 폴백: RPC
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
      // 1) 우선 호환 VIEW 시도
      final viaView = await _selectFrom(SupabaseTables.lessonLinks);
      if (viaView.isNotEmpty) return viaView;

      // 2) VIEW가 비었거나 매핑 문제 시 실테이블 폴백
      final viaTable = await _selectFrom(SupabaseTables.lessonResourceLinks);
      return viaTable;
    } catch (_) {
      // VIEW가 없거나 권한/스키마 캐시 이슈면 바로 실테이블로
      try {
        return await _selectFrom(SupabaseTables.lessonResourceLinks);
      } catch (_) {
        return const [];
      }
    }
  }

  Future<List<Map<String, dynamic>>> listTodayByStudent(
    String studentId, {
    bool ensure = false,
  }) async {
    // 목록 조회에서도 오늘 레슨 ID를 보장해버리자(불일치 차단)
    final lessonId = await getTodayLessonId(studentId, ensure: ensure);
    if (lessonId == null) return const [];
    return listByLesson(lessonId);
  }
}
