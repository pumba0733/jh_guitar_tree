// lib/services/lesson_links_service.dart
// v1.45.1 | 링크 서비스 - unnecessary_type_check 경고 제거 (Supabase select()의 List 반환에 대한 명시 캐스팅)
// - RPC: ensure_today_lesson / link_node_to_today_lesson / link_resource_to_today_lesson
// - 삭제: lesson_links RLS delete 정책으로 안전하게 동작

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

      // ⬇️ unnecessary_type_check 제거: select()는 항상 List 반환 → 명시 캐스팅
      final list = (rows as List);
      if (list.isEmpty) return null;
      return (list.first['id'] ?? '').toString();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _ensureTodayLessonId(String studentId) async {
    return _rpcString('ensure_today_lesson', {'p_student_id': studentId});
  }

  Future<String?> getTodayLessonId(
    String studentId, {
    bool ensure = false,
  }) async {
    String? id = await _findTodayLessonId(studentId);
    if (id == null && ensure) {
      id = await _ensureTodayLessonId(studentId);
    }
    return id;
  }

  Future<bool> deleteById(String id) async {
    try {
      await _retry(
        () => _c.from(SupabaseTables.lessonLinks).delete().eq('id', id),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> sendNodeToTodayLessonId({
    required String studentId,
    required String nodeId,
  }) {
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

  Future<String?> sendResourceToTodayLessonId({
    required String studentId,
    required ResourceFile resource,
  }) {
    return _rpcString('link_resource_to_today_lesson', {
      'p_student_id': studentId,
      'p_bucket': resource.storageBucket,
      'p_path': resource.storagePath,
      'p_filename': resource.filename,
      'p_title': resource.title,
    });
    // 서버 함수 시그니처: (uuid, text, text, text, text) → uuid
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

  Future<List<Map<String, dynamic>>> listByLesson(String lessonId) async {
    try {
      final rows = await _retry(
        () => _c
            .from(SupabaseTables.lessonLinks)
            .select()
            .eq('lesson_id', lessonId)
            .order('created_at', ascending: false),
      );

      // ⬇️ unnecessary_type_check 제거 + 안전 매핑
      final list = (rows as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);

      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> listTodayByStudent(
    String studentId, {
    bool ensure = false,
  }) async {
    String? lessonId = await _findTodayLessonId(studentId);
    if (lessonId == null && ensure) {
      lessonId = await _ensureTodayLessonId(studentId);
    }
    if (lessonId == null) return const [];
    return listByLesson(lessonId);
  }
}
