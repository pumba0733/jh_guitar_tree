// lib/services/lesson_links_service.dart
// v1.66 | 오늘 수업 리소스 수집 + 실행 유틸 + 링크 보장 래퍼 추가
// - ensureTodayLessonAndLinkResource(studentId, resource) 추가
// - listTodayByStudent: 뷰 단독 조회 → 테이블 우선(listByLesson)로 변경 (뷰/RLS 이슈 회피)

import 'dart:async';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/resource.dart';
import '../supabase/supabase_tables.dart';
import './xsc_sync_service.dart';

class TodayResources {
  final List<LessonLinkItem> links;
  final List<LessonAttachmentItem> atts;
  const TodayResources({required this.links, required this.atts});
}

class LessonLinkItem {
  final String id;
  final String lessonId;
  final String? title;
  final String resourceBucket;
  final String resourcePath;
  final String resourceFilename;
  final DateTime createdAt;
  const LessonLinkItem({
    required this.id,
    required this.lessonId,
    required this.title,
    required this.resourceBucket,
    required this.resourcePath,
    required this.resourceFilename,
    required this.createdAt,
  });
}

class LessonAttachmentItem {
  final String lessonId;
  final String type; // 'xsc' | 'file' | 'url'
  final String? localPath;
  final String? url;
  final String? path;
  final String? originalFilename;
  final String? mediaName;
  final String? xscStoragePath;
  final DateTime? xscUpdatedAt;
  final DateTime createdAt;
  const LessonAttachmentItem({
    required this.lessonId,
    required this.type,
    required this.createdAt,
    this.localPath,
    this.url,
    this.path,
    this.originalFilename,
    this.mediaName,
    this.xscStoragePath,
    this.xscUpdatedAt,
  });
}

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
      final list = rows as List;
      if (list.isEmpty) return null;
      final first = list.first as Map;
      return (first['id'] ?? '').toString();
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
      final ensuredId = await _ensureTodayLessonId(studentId);
      id = ensuredId ?? await _findTodayLessonId(studentId);
    }
    return id;
  }

  Future<String?> getTodayLessonIdEnsure(String studentId) {
    return getTodayLessonId(studentId, ensure: true);
  }

  // ---------- INSERT (리소스/노드) ----------

  Future<String?> _insertResourceLinkDirect({
    required String lessonId,
    required ResourceFile resource,
  }) async {
    Future<String?> ins(String table) async {
      final payload = <String, dynamic>{
        'lesson_id': lessonId,
        'kind': 'resource',
        'resource_bucket': resource.storageBucket,
        'resource_path': resource.storagePath,
        'resource_filename': resource.filename,
        if ((resource.title ?? '').toString().isNotEmpty)
          'resource_title': resource.title,
      };
      try {
        final row = await _retry(
          () => _c.from(table).insert(payload).select('id').single(),
        );
        final id = (row['id'] ?? '').toString();
        // 👇 계측
        print('[LLS] insert into $table ok id=$id payload=$payload');
        return id.isNotEmpty ? id : null;
      } catch (e) {
        print('[LLS] insert into $table failed: $e');
        rethrow;
      }
    }

    try {
      try {
        final viaView = await ins(SupabaseTables.lessonLinks);
        if (viaView != null) return viaView;
      } catch (_) {}
      return await ins(SupabaseTables.lessonResourceLinks);
    } catch (e) {
      print('[LLS] both insert paths failed, fallback to RPC: $e');
      return null;
    }
  }

  Future<String?> _insertNodeLinkDirect({
    required String lessonId,
    required String nodeId,
  }) async {
    Future<String?> ins(String table) async {
      final payload = <String, dynamic>{
        'lesson_id': lessonId,
        'kind': 'node',
        'curriculum_node_id': nodeId,
      };
      final row = await _retry(
        () => _c.from(table).insert(payload).select('id').single(),
      );
      final id = (row['id'] ?? '').toString();
      return id.isNotEmpty ? id : null;
    }

    try {
      try {
        final viaView = await ins(SupabaseTables.lessonLinks);
        if (viaView != null) return viaView;
      } catch (_) {}
      return await ins(SupabaseTables.lessonResourceLinks);
    } catch (_) {
      return null;
    }
  }

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

  Future<String?> sendNodeToTodayLessonId({
    required String studentId,
    required String nodeId,
  }) async {
    final lessonId = await getTodayLessonId(studentId, ensure: true);
    if (lessonId != null) {
      final direct = await _insertNodeLinkDirect(
        lessonId: lessonId,
        nodeId: nodeId,
      );
      if (direct != null) return direct;
    }
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

  /// ✅ v1.66: 오늘레슨 보장 + 리소스 링크 1-shot
  Future<String?> ensureTodayLessonAndLinkResource({
    required String studentId,
    required ResourceFile resource,
  }) async {
    await getTodayLessonIdEnsure(studentId);
    return sendResourceToTodayLessonId(
      studentId: studentId,
      resource: resource,
    );
  }

  // ---------- 조회 ----------

  Future<List<Map<String, dynamic>>> listByLesson(String lessonId) async {
    Future<List<Map<String, dynamic>>> selectFrom(String table) async {
      final rows = await _retry(
        () => _c
            .from(table)
            .select()
            .eq('lesson_id', lessonId)
            .order('created_at', ascending: false),
      );
      return (rows as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }

    // 🔧 뷰가 깨져있어도 동작하도록: 테이블 먼저 → 실패/빈결과면 뷰 시도
    try {
      final viaTable = await selectFrom(SupabaseTables.lessonResourceLinks);
      if (viaTable.isNotEmpty) return viaTable;
    } catch (_) {}

    try {
      return await selectFrom(SupabaseTables.lessonLinks); // (뷰)
    } catch (_) {
      return const [];
    }
  }

  // ---------- v1.66: 오늘 수업 리소스 묶어서 반환 ----------

  Future<TodayResources> fetchTodayResources({
    required String studentId,
  }) async {
    final lessonId = await getTodayLessonIdEnsure(studentId);
    final links = <LessonLinkItem>[];
    final atts = <LessonAttachmentItem>[];

    if (lessonId == null) return TodayResources(links: links, atts: atts);

    final linkRows = await listByLesson(lessonId);
    for (final m in linkRows) {
      final mm = Map<String, dynamic>.from(m);
      final kind = (mm['kind'] ?? '').toString();
      if (kind != 'resource') continue;

      links.add(
        LessonLinkItem(
          id: (mm['id'] ?? '').toString(),
          lessonId: (mm['lesson_id'] ?? '').toString(),
          title: (() {
            final t = (mm['resource_title'] ?? '').toString();
            if (t.isNotEmpty) return t;
            final f = (mm['resource_filename'] ?? '').toString();
            return f.isNotEmpty ? f : null;
          })(),
          resourceBucket: (mm['resource_bucket'] ?? '').toString(),
          resourcePath: (mm['resource_path'] ?? '').toString(),
          resourceFilename: (mm['resource_filename'] ?? 'resource').toString(),
          createdAt:
              DateTime.tryParse((mm['created_at'] ?? '').toString()) ??
              DateTime.now(),
        ),
      );
    }

    // lessons.attachments (배열) → 호환 유지 (null-safe)
    try {
      final row = await _retry<Map<String, dynamic>?>(
        () => _c
            .from(SupabaseTables.lessons)
            .select('attachments, date')
            .eq('id', lessonId)
            .maybeSingle(),
      );

      final attachmentsAny = (row?['attachments']);
      if (attachmentsAny is List) {
        for (final e in attachmentsAny) {
          final map = (e is Map)
              ? Map<String, dynamic>.from(e as Map)
              : <String, dynamic>{
                  'url': e.toString(),
                  'path': e.toString(),
                  'name': e.toString().split('/').last,
                };

          atts.add(
            LessonAttachmentItem(
              lessonId: lessonId,
              type: (map['type'] ?? 'url').toString(),
              localPath: (map['localPath'] ?? '').toString().isNotEmpty
                  ? map['localPath'].toString()
                  : null,
              url: (map['url'] ?? '').toString().isNotEmpty
                  ? map['url'].toString()
                  : null,
              path: (map['path'] ?? '').toString().isNotEmpty
                  ? map['path'].toString()
                  : null,
              originalFilename: (map['name'] ?? '').toString().isNotEmpty
                  ? map['name'].toString()
                  : null,
              mediaName: (map['mediaName'] ?? '').toString().isNotEmpty
                  ? map['mediaName'].toString()
                  : null,
              xscStoragePath:
                  (map['xscStoragePath'] ?? '').toString().isNotEmpty
                  ? map['xscStoragePath'].toString()
                  : null,
              xscUpdatedAt: DateTime.tryParse(
                (map['xscUpdatedAt'] ?? '').toString(),
              ),
              createdAt: DateTime.now(),
            ),
          );
        }
      }
    } catch (_) {}

    return TodayResources(links: links, atts: atts);
  }

  // ---------- 실행 유틸 ----------

  Future<void> openFromLessonLink(
    LessonLinkItem link, {
    required String studentId,
  }) async {
    final map = {
      'id': link.id,
      'lesson_id': link.lessonId,
      'kind': 'resource',
      'resource_title': link.title,
      'resource_bucket': link.resourceBucket,
      'resource_path': link.resourcePath,
      'resource_filename': link.resourceFilename,
      'created_at': link.createdAt.toIso8601String(),
    };
    await XscSyncService().openFromLessonLinkMap(
      link: map,
      studentId: studentId,
    );
  }

  Future<void> openFromAttachment(
    LessonAttachmentItem att, {
    required String studentId,
  }) async {
    final map = <String, dynamic>{
      if ((att.url ?? '').isNotEmpty) 'url': att.url,
      if ((att.path ?? '').isNotEmpty) 'path': att.path,
      if ((att.originalFilename ?? '').isNotEmpty) 'name': att.originalFilename,
      if ((att.mediaName ?? '').isNotEmpty) 'mediaName': att.mediaName,
      if ((att.xscStoragePath ?? '').isNotEmpty)
        'xscStoragePath': att.xscStoragePath,
    };
    await XscSyncService().openFromAttachment(
      attachment: map,
      studentId: studentId,
      mimeType: null,
    );
  }

  // ---------- 메타 보조 ----------
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

  Future<void> upsertAttachmentXscMeta({
    required String studentId,
    required String mp3Hash,
    required String xscStoragePath,
  }) async {
    try {
      await _c.rpc(
        'upsert_attachment_xsc_meta',
        params: {
          'p_student_id': studentId,
          'p_mp3_hash': mp3Hash,
          'p_xsc_storage_path': xscStoragePath,
        },
      );
    } catch (_) {}
  }

  /// 오늘 레슨의 리소스/노드 링크 목록
  Future<List<Map<String, dynamic>>> listTodayByStudent(
    String studentId, {
    bool ensure = false,
  }) async {
    final lessonId = ensure
        ? await getTodayLessonIdEnsure(studentId)
        : await getTodayLessonId(studentId, ensure: false);
    print(
      '[LLS] listTodayByStudent student=$studentId lessonId=$lessonId ensure=$ensure',
    );
    if (lessonId == null) return const [];

    // ✅ 핵심 수정: 테이블 우선(뷰 RLS/정의 이슈 회피) → 비면 최종적으로 뷰 한 번 더 시도
    final viaTableOrView = await listByLesson(lessonId);
    if (viaTableOrView.isNotEmpty) return viaTableOrView;

    try {
      final rows = await _c
          .from('lesson_links')
          .select(
            'id, lesson_id, kind, curriculum_node_id, resource_bucket, resource_path, resource_filename, resource_title, created_at',
          )
          .eq('lesson_id', lessonId)
          .order('created_at', ascending: false);

      return (rows as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
