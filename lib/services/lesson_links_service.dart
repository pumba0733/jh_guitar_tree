// lib/services/lesson_links_service.dart
// v1.70 | 오늘 레슨에 '담기' 일괄 추가 API (링크·첨부) + 중복 방지 머지
// - AddItem/AddResult 도입
// - addResourceLinkMapsToToday / addAttachmentsToTodayLesson / 단건 헬퍼 추가
// - 기존 ensureTodayLessonAndLinkResource 등 시그니처/동작 유지

import 'dart:async';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import './file_service.dart';
import './resource_service.dart';
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

// ===== v1.70 추가: 담기 API용 모델 =====
class AddItem {
  final Map<String, dynamic> src; // link row(map) 또는 attachment map
  final String kind; // 'link' | 'attachment'
  const AddItem.link(this.src) : kind = 'link';
  const AddItem.attachment(this.src) : kind = 'attachment';
}

class AddResult {
  final int added;
  final int duplicated;
  final int failed;
  const AddResult({
    required this.added,
    required this.duplicated,
    required this.failed,
  });
  @override
  String toString() =>
      'AddResult(added=$added, duplicated=$duplicated, failed=$failed)';
}

class LessonLinksService {
  final SupabaseClient _c = Supabase.instance.client;

  // ---------- 공통 유틸 ----------
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

  // ---------- 내부: 오늘 레슨 ID 조회/보장 ----------
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
      final id = (first['id'] ?? '').toString();
      return id.isNotEmpty ? id : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _ensureTodayLessonId(String studentId) async {
    return _rpcString('ensure_today_lesson', {'p_student_id': studentId});
  }

  /// ✅ 항상 ensure 경로만 사용
  Future<String?> getTodayLessonIdEnsure(String studentId) async {
    final ensured = await _ensureTodayLessonId(studentId);
    if ((ensured ?? '').isNotEmpty) return ensured;
    final found = await _findTodayLessonId(studentId);
    if ((found ?? '').isNotEmpty) return found;
    return null;
  }

  @Deprecated('getTodayLessonIdEnsure(studentId)를 사용하세요(내부 ensure).')
  Future<String?> getTodayLessonId(
    String studentId, {
    bool ensure = false,
  }) async {
    if (!ensure) {
      // ignore: avoid_print
      print(
        '[LLS][DEPRECATED] getTodayLessonId(..., ensure:$ensure) → ensure 강제',
      );
    }
    return getTodayLessonIdEnsure(studentId);
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
        // ignore: avoid_print
        print('[LLS] insert into $table ok id=$id payload=$payload');
        return id.isNotEmpty ? id : null;
      } catch (e) {
        // ignore: avoid_print
        print('[LLS] insert into $table failed: $e');
        rethrow;
      }
    }

    try {
      try {
        final viaView = await ins(SupabaseTables.lessonLinks); // VIEW
        if (viaView != null) return viaView;
      } catch (_) {}
      return await ins(SupabaseTables.lessonResourceLinks); // TABLE
    } catch (e) {
      // ignore: avoid_print
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
    final lessonId = await getTodayLessonIdEnsure(studentId);
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
    final lessonId = await getTodayLessonIdEnsure(studentId);
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

  /// ✅ 유지: 오늘레슨 보장 + 단건 링크
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
            .select(
              'id, lesson_id, kind, curriculum_node_id, '
              'resource_bucket, resource_path, resource_filename, resource_title, created_at',
            )
            .eq('lesson_id', lessonId)
            .order('created_at', ascending: false),
      );
      return (rows as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }

    try {
      final viaTable = await selectFrom(SupabaseTables.lessonResourceLinks);
      if (viaTable.isNotEmpty) return viaTable;
    } catch (_) {}

    try {
      return await selectFrom(SupabaseTables.lessonLinks); // VIEW
    } catch (_) {
      return const [];
    }
  }

  // ---------- 오늘 수업 리소스 묶음 ----------
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
    // 리소스 모델 구성
    final rf = ResourceFile.fromMap({
      'id': '',
      'curriculum_node_id': null,
      'title': link.title,
      'filename': link.resourceFilename,
      'mime_type': null,
      'size_bytes': null,
      'storage_bucket': link.resourceBucket,
      'storage_path': link.resourcePath,
      'created_at': link.createdAt.toIso8601String(),
    });

    // ✅ XSC 대상 미디어면 XscSyncService 경로, 아니면 워크스페이스 저장 후 기본앱
    final xsc = XscSyncService();
    if (xsc.isMediaEligibleForXsc(rf)) {
      await xsc.open(resource: rf, studentId: studentId);
    } else {
      final url = await ResourceService().signedUrl(rf);
      await FileService().saveUrlToWorkspaceAndOpen(
        studentId: studentId,
        filename: rf.filename,
        url: url,
      );
    }
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
    };
    await FileService().openAttachment(map);
  }

  // ---------- v1.70: 오늘 레슨에 '담기' 일괄 추가 ----------
  // 링크(lesson_links) 다건 추가 - 중복 방지
  Future<AddResult> addResourceLinkMapsToToday({
    required String studentId,
    required List<Map<String, dynamic>> linkRows,
  }) async {
    final lessonId = await getTodayLessonIdEnsure(studentId);
    if (lessonId == null) {
      return const AddResult(added: 0, duplicated: 0, failed: 1);
    }

    // 기존 링크 세트 로드(중복 방지)
    final existing = await listByLesson(lessonId);
    final existingKeys = existing
        .where((e) => (e['kind'] ?? '') == 'resource')
        .map((e) => _linkKeyFrom(e))
        .where((k) => k.isNotEmpty)
        .toSet();

    int added = 0, dup = 0, failed = 0;

    for (final l in linkRows) {
      final m = Map<String, dynamic>.from(l);
      final key = _linkKeyFrom(m);
      if (key.isEmpty) {
        failed++;
        continue;
      }
      if (existingKeys.contains(key)) {
        dup++;
        continue;
      }

      final rf = ResourceFile.fromMap({
        'id': (m['id'] ?? '').toString(),
        'curriculum_node_id': m['curriculum_node_id'],
        'title': (() {
          final t = (m['resource_title'] ?? '').toString();
          return t.isEmpty ? null : t;
        })(),
        'filename': (m['resource_filename'] ?? 'resource').toString(),
        'mime_type': null,
        'size_bytes': null,
        'storage_bucket': (m['resource_bucket'] ?? ResourceService.bucket)
            .toString(),
        'storage_path': (m['resource_path'] ?? '').toString(),
        'created_at': m['created_at'],
      });

      try {
        final id = await _insertResourceLinkDirect(
          lessonId: lessonId,
          resource: rf,
        );
        if (id != null) {
          existingKeys.add(key);
          added++;
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }

    return AddResult(added: added, duplicated: dup, failed: failed);
  }

  // 첨부(lessons.attachments JSONB) 다건 추가 - 중복 방지 병합
  Future<AddResult> addAttachmentsToTodayLesson({
    required String studentId,
    required List<Map<String, dynamic>> attachments,
  }) async {
    final lessonId = await getTodayLessonIdEnsure(studentId);
    if (lessonId == null) {
      return const AddResult(added: 0, duplicated: 0, failed: 1);
    }

    // 현재 attachments 로드
    final row = await _retry<Map<String, dynamic>?>(
      () => _c
          .from(SupabaseTables.lessons)
          .select('attachments')
          .eq('id', lessonId)
          .maybeSingle(),
    );
    final current = <Map<String, dynamic>>[];
    final keys = <String>{};

    if (row != null && row['attachments'] is List) {
      for (final e in (row['attachments'] as List)) {
        final m = (e is Map)
            ? Map<String, dynamic>.from(e)
            : <String, dynamic>{'url': e.toString(), 'name': e.toString()};
        current.add(m);
        keys.add(_attachmentKeyOf(m));
      }
    }

    int added = 0, dup = 0, failed = 0;

    for (final a in attachments) {
      final m = Map<String, dynamic>.from(a);
      final k = _attachmentKeyOf(m);
      if (k.isEmpty) {
        failed++;
        continue;
      }
      if (keys.contains(k)) {
        dup++;
        continue;
      }
      current.add(m);
      keys.add(k);
      added++;
    }

    try {
      await _retry(
        () => _c
            .from(SupabaseTables.lessons)
            .update({'attachments': current})
            .eq('id', lessonId),
      );
    } catch (_) {
      // 업데이트 실패 시 전체를 실패로 되돌리지 않음(낙관적)
    }

    return AddResult(added: added, duplicated: dup, failed: failed);
  }

  // 단건 헬퍼
  Future<AddResult> addResourceLinkMapToToday({
    required String studentId,
    required Map<String, dynamic> linkRow,
  }) => addResourceLinkMapsToToday(studentId: studentId, linkRows: [linkRow]);

  Future<AddResult> addAttachmentMapToToday({
    required String studentId,
    required Map<String, dynamic> attachment,
  }) => addAttachmentsToTodayLesson(
    studentId: studentId,
    attachments: [attachment],
  );

  // 첨부 중복판정 키
  String _attachmentKeyOf(Map<String, dynamic> m) {
    final lp = (m['localPath'] ?? '').toString();
    if (lp.isNotEmpty) return 'local::$lp';
    final url = (m['url'] ?? '').toString();
    if (url.isNotEmpty) return 'url::$url';
    final path = (m['path'] ?? '').toString();
    if (path.isNotEmpty) return 'path::$path';
    final name = (m['name'] ?? '').toString();
    if (name.isNotEmpty) return 'name::$name';
    return '';
  }

  // 링크 중복판정 키(버킷+경로)
  String _linkKeyFrom(Map<String, dynamic> m) {
    final bucket = ((m['resource_bucket'] ?? ResourceService.bucket)
        .toString()
        .trim()
        .toLowerCase());
    final path = ((m['resource_path'] ?? '').toString().trim());
    if (bucket.isEmpty || path.isEmpty) return '';
    return '$bucket::$path';
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

  /// 오늘 레슨 링크 목록(ensure 강제)
  Future<List<Map<String, dynamic>>> listTodayByStudent(
    String studentId, {
    bool ensure = false, // 호환용
  }) async {
    final lessonId = await getTodayLessonIdEnsure(studentId);
    // ignore: avoid_print
    print(
      '[LLS] listTodayByStudent student=$studentId lessonId=$lessonId (ensure=forced)',
    );
    if (lessonId == null) return const [];
    final viaTableOrView = await listByLesson(lessonId);
    if (viaTableOrView.isNotEmpty) return viaTableOrView;

    try {
      final rows = await _c
          .from(SupabaseTables.lessonLinks)
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

// v1.61 | Storage Key ASCII-safe 유틸 + 표준 경로
class FileKeyUtil {
  // 영문/숫자/._- 만 허용, 나머지는 '_'
  static String keySafe(String input) {
    final buf = StringBuffer();
    for (final ch in input.runes) {
      final c = String.fromCharCode(ch);
      final ok = RegExp(r'[A-Za-z0-9._-]').hasMatch(c);
      buf.write(ok ? c : '_');
    }
    var s = buf.toString();
    s = s.replaceAll(RegExp(r'_+'), '_');
    s = s.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
    return s.isEmpty ? '_' : s;
  }

  /// 표준 첨부 경로: lesson/{lessonId}/{uuid}.ext  (ext는 ".xsc" 형태)
  static String lessonAttachmentKey({
    required String lessonId,
    required String uuid,
    required String ext, // ".xsc" 같은 형태(점 포함/미포함 허용)
  }) {
    final e = ext.startsWith('.') ? ext : '.$ext';
    return 'lesson/$lessonId/$uuid${e.toLowerCase()}';
  }
}
