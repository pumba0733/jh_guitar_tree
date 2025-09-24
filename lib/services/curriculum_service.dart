// lib/services/curriculum_service.dart
// v1.46.6 | 배정 리소스 조회 경로 수정 (inFilter 사용) + 미사용 상수 정리
// - FIX: .in_() → .inFilter('col', values)
// - CHORE: 미사용 _tNodeRes 제거
// - 나머지 기존 기능 유지

import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException, HttpException;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class CurriculumService {
  final SupabaseClient _c = Supabase.instance.client;

  // ---------- Table / RPC ----------
  static const _tNodes = 'curriculum_nodes';
  static const _tAssign = 'curriculum_assignments';
  static const _tRes = 'resources';
  static const _rpcVisibleTree = 'list_visible_curriculum_tree';

  // ---------- Deep Links ----------
  static const String _appDeepLinkBase = 'guitartree://curriculum';
  static const String _webDeepLinkBase =
      'https://app.guitartree.local/curriculum';

  bool? _hasVisibleTreeRpc; // lazy capability cache

  // ---------- Helpers ----------
  List<Map<String, dynamic>> _mapList(dynamic data) {
    final list = (data as List<dynamic>? ?? const []);
    return list
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
  }

  Map<String, dynamic> _mapOne(dynamic row) =>
      Map<String, dynamic>.from(row as Map);

  Future<T> _retry<T>(
    Future<T> Function() task, {
    int maxAttempts = 3,
    Duration baseDelay = const Duration(milliseconds: 250),
    Duration timeout = const Duration(seconds: 20),
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
            shouldRetry?.call(e) ??
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

  // ---------- Policy Guards ----------
  bool _isRoot(String? parentId) => parentId == null;
  void _ensureNotRootFile({required String? parentId, required String type}) {
    if (_isRoot(parentId) && type.trim() == 'file') {
      throw StateError('루트(depth 0)에는 file 타입을 만들 수 없습니다. (category만 허용)');
    }
  }

  // ---------- Deep Link Utils ----------
  String buildBrowserUrl(String nodeId, {bool preferAppScheme = true}) {
    final id = nodeId.trim();
    if (id.isEmpty) {
      throw ArgumentError('buildBrowserUrl: nodeId가 비어있습니다.');
    }
    final base = preferAppScheme ? _appDeepLinkBase : _webDeepLinkBase;
    return '$base?node=$id';
  }

  Future<void> openInBrowser(
    String nodeId, {
    bool preferAppScheme = true,
  }) async {
    final url = buildBrowserUrl(nodeId, preferAppScheme: preferAppScheme);
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) {
      throw StateError('브라우저/앱으로 열기 실패: $url');
    }
  }

  Future<void> _ensureAuthSession() async {
    if (_c.auth.currentUser == null) {
      try {
        await _c.auth.signInAnonymously();
      } catch (_) {}
    }
  }

  // ---------- Reads ----------
  Future<List<Map<String, dynamic>>> listNodes() async {
    if (_hasVisibleTreeRpc != false) {
      try {
        final data = await _retry(() => _c.rpc(_rpcVisibleTree));
        final list = _mapList(data);
        _hasVisibleTreeRpc = true;
        if (list.isNotEmpty) return list; // ✅ 비어있으면 폴백
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('does not exist') ||
            msg.contains('not exist') ||
            msg.contains('42883')) {
          _hasVisibleTreeRpc = false;
        }
      }
    }
    final data = await _retry(
      () => _c
          .from(_tNodes)
          .select()
          .order('parent_id', ascending: true, nullsFirst: true)
          .order('order', ascending: true)
          .order('created_at', ascending: true),
    );
    return _mapList(data);
  }

  Future<List<Map<String, dynamic>>> listReviewedResourcesByStudent(
    String studentId, {
    int limit = 100,
  }) async {
    final data = await _retry(
      () => _c.rpc(
        'list_reviewed_resources_by_student',
        params: {'p_student_id': studentId, 'p_limit': limit},
      ),
    );
    return _mapList(data);
  }

  Future<void> ensureStudentBinding(String studentId) async {
    try {
      await Supabase.instance.client.rpc(
        'attach_me_to_student',
        params: {'p_student_id': studentId},
      );
    } catch (_) {
      // 조용히 무시 (권한/상태에 따라 실패할 수 있음)
    }
  }

  Future<List<Map<String, dynamic>>> listNodesByParent(String? parentId) async {
    final base = _c.from(_tNodes).select();
    final filtered = parentId == null
        ? base.filter('parent_id', 'is', null)
        : base.eq('parent_id', parentId);
    final data = await _retry(
      () => filtered
          .order('order', ascending: true)
          .order('created_at', ascending: true),
    );
    return _mapList(data);
  }

  Future<Map<String, dynamic>?> getNode(String id) async {
    final data = await _retry(
      () => _c.from(_tNodes).select().eq('id', id).maybeSingle(),
    );
    if (data == null) return null;
    return _mapOne(data);
  }

  // ---------- Assignments ----------
  // ---------- Assignments ----------
  Future<List<Map<String, dynamic>>> listAssignmentsByStudent(
    String studentId,
  ) async {
    // 0) 학생-세션 연결이 안되어 있으면 붙여둔다(무해, 실패시 무시)
    try {
      await Supabase.instance.client.rpc(
        'attach_me_to_student',
        params: {'p_student_id': studentId},
      );
    } catch (_) {}

    // 1) SECURITY DEFINER RPC 우선 (RLS 우회 X, 서버에서 권한 체크)
    try {
      final data = await _retry(
        () => _c.rpc(
          'list_assignments_by_student',
          params: {'p_student_id': studentId},
        ),
        // attach 직후 반영 지연 대비 재시도 허용
        shouldRetry: (_) => true,
      );
      final list = _mapList(data);
      if (list.isNotEmpty) return list;
      // 비어있으면 아래 폴백으로 시도
    } catch (_) {
      /* 폴백 */
    }

    // 2) 폴백: 직접 테이블 조회(교사/관리자 세션에서만 통과될 수 있음)
    final data = await _retry(
      () => _c.from(_tAssign).select().eq('student_id', studentId),
    );
    return _mapList(data);
  }

  Future<List<Map<String, dynamic>>> listAssignmentsByNode(
    String nodeId,
  ) async {
    final data = await _retry(
      () => _c.from(_tAssign).select().eq('curriculum_node_id', nodeId),
    );
    return _mapList(data);
  }

  Future<Map<String, dynamic>?> assignNodeToStudent({
    required String studentId,
    required String nodeId,
    List<String>? path,
    String? filePath,
  }) async {
    if (studentId.trim().isEmpty || nodeId.trim().isEmpty) {
      throw ArgumentError('assignNodeToStudent: studentId/nodeId 누락');
    }
    final payload = <String, dynamic>{
      'student_id': studentId,
      'curriculum_node_id': nodeId,
      if (path != null) 'path': path,
      if (filePath != null) 'file_path': filePath,
    };
    final upserted = await _retry(
      () => _c
          .from(_tAssign)
          .upsert(payload, onConflict: 'student_id,curriculum_node_id')
          .select()
          .maybeSingle(),
    );
    return upserted == null ? null : _mapOne(upserted);
  }

  Future<int> assignNodeToStudents({
    required List<String> studentIds,
    required String nodeId,
  }) async {
    if (studentIds.isEmpty) return 0;
    final rows = studentIds
        .where((s) => s.trim().isNotEmpty)
        .map((s) => {'student_id': s.trim(), 'curriculum_node_id': nodeId})
        .toList(growable: false);
    final res = await _retry(
      () => _c
          .from(_tAssign)
          .upsert(rows, onConflict: 'student_id,curriculum_node_id')
          .select(),
    );
    return (res as List).length;
  }

  Future<void> unassignNodeFromStudent({
    required String studentId,
    required String nodeId,
  }) async {
    await _retry(
      () => _c
          .from(_tAssign)
          .delete()
          .eq('student_id', studentId)
          .eq('curriculum_node_id', nodeId),
    );
  }

  // ---------- Nodes CRUD ----------
  Future<Map<String, dynamic>> createNode({
    String? parentId,
    String type = 'category', // 'category' | 'file'
    required String title,
    String? fileUrl,
    int? order,
    Map<String, dynamic>? extra,
  }) async {
    if (title.trim().isEmpty) {
      throw ArgumentError('createNode: title이 필요합니다.');
    }
    _ensureNotRootFile(parentId: parentId, type: type);

    final payload = <String, dynamic>{
      if (parentId != null) 'parent_id': parentId,
      'type': type,
      'title': title.trim(),
      if (fileUrl != null) 'file_url': fileUrl,
      if (order != null) 'order': order,
      if (extra != null) ...extra,
    };
    final inserted = await _retry(
      () => _c.from(_tNodes).insert(payload).select().single(),
    );
    return _mapOne(inserted);
  }

  Future<Map<String, dynamic>> updateNode({
    required String id,
    String? parentId,
    String? type,
    String? title,
    String? fileUrl,
    int? order,
    Map<String, dynamic>? extra,
  }) async {
    if (id.trim().isEmpty) {
      throw ArgumentError('updateNode: id 누락');
    }
    final before = await getNode(id);
    if (before == null) {
      throw StateError('updateNode: 대상 노드를 찾을 수 없습니다. id=$id');
    }
    final newParentId = parentId ?? before['parent_id'];
    final newType = (type ?? before['type'] ?? '').toString();
    _ensureNotRootFile(parentId: newParentId, type: newType);

    final payload = <String, dynamic>{
      if (parentId != null) 'parent_id': parentId,
      if (type != null) 'type': type,
      if (title != null) 'title': title.trim(),
      if (fileUrl != null) 'file_url': fileUrl,
      if (order != null) 'order': order,
      if (extra != null) ...extra,
    };
    final updated = await _retry(
      () => _c.from(_tNodes).update(payload).eq('id', id).select().single(),
    );
    return _mapOne(updated);
  }

  Future<Map<String, dynamic>> moveNode({
    required String id,
    String? newParentId,
    int? newOrder,
  }) {
    return updateNode(id: id, parentId: newParentId, order: newOrder);
  }

  Future<void> deleteNode(String id, {bool recursive = false}) async {
    if (!recursive) {
      await _retry(() => _c.from(_tNodes).delete().eq('id', id));
      return;
    }
    final children = await listNodesByParent(id);
    for (final ch in children) {
      final cid = (ch['id'] ?? '').toString();
      if (cid.isEmpty) continue;
      await deleteNode(cid, recursive: true);
    }
    await _retry(() => _c.from(_tNodes).delete().eq('id', id));
  }

  // ---------- NEW: 학생 기준 배정 리소스 조회 (서비스단 dedupe 포함) ----------
  Future<List<Map<String, dynamic>>> fetchAssignedResourcesForStudent(
    String studentId,
  ) async {
    // ⬇️ 세션/바인딩 보장
    await _ensureAuthSession();
    await ensureStudentBinding(studentId);

    // 1) 배정된 노드 목록
    final assigns = await _retry(() async {
      return await _c
          .from(_tAssign)
          .select('curriculum_node_id')
          .eq('student_id', studentId);
    });
    final nodeIds = <String>{
      for (final r in (assigns as List))
        if ((r as Map)['curriculum_node_id']?.toString().isNotEmpty ?? false)
          r['curriculum_node_id'].toString(),
    };
    if (nodeIds.isEmpty) return const [];

    // 2) 해당 노드의 파일 리소스
    final data = await _retry(() async {
      return await _c
          .from(_tRes)
          .select(
            'id,title,filename,original_filename,content_hash,'
            'storage_bucket,storage_path,curriculum_node_id,'
            'mime_type,size_bytes,created_at',
          )
          .inFilter('curriculum_node_id', nodeIds.toList())
          .order('created_at', ascending: false);
    });

    // 3) 클라이언트 이중 방어(널/공백 제거) + dedupe(bucket::path::filename)
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];

    String _trimSlashes(String s) => s.replaceAll(RegExp(r'^/+|/+$'), '');

    for (final m in _mapList(data)) {
      final path = _trimSlashes((m['storage_path'] ?? '').toString().trim());
      final filename = (m['filename'] ?? '').toString().trim();
      final bucket = (m['storage_bucket'] ?? '')
          .toString()
          .trim()
          .toLowerCase();

      if (path.isEmpty || filename.isEmpty || bucket.isEmpty) continue;

      final key = '$bucket::$path::$filename';
      if (seen.add(key)) out.add(m);
    }
    return out;
  }

  /// 학생 배정 리소스 검색 (제목/파일명 기준)
  Future<List<Map<String, dynamic>>> searchAssignedResourcesForStudent(
    String studentId,
    String query,
  ) async {
    await _ensureAuthSession();
    await ensureStudentBinding(studentId);

    // 0) 검색어 전처리
    final raw = (query).trim();
    if (raw.isEmpty) return const [];
    // PostgREST .or() 안정화를 위해 콤마/괄호 제거
    final safe = raw.replaceAll(RegExp(r'[,\(\)]'), ' ').trim();
    if (safe.isEmpty) return const [];

    // 1) 배정된 노드 확보
    final assigns = await _retry(() async {
      return await _c
          .from(_tAssign)
          .select('curriculum_node_id')
          .eq('student_id', studentId);
    });
    final nodeIds = <String>{
      for (final r in (assigns as List))
        if ((r as Map)['curriculum_node_id']?.toString().isNotEmpty ?? false)
          r['curriculum_node_id'].toString(),
    };
    if (nodeIds.isEmpty) return const [];

    // 2) 서버 검색: original_filename / filename / title
    //    Supabase(PostgREST)에서는 ilike.*foo* 패턴이 안전함
    // 2) 서버 검색: original_filename / filename / title
    // PostgREST의 .or() 안에서는 ilike.*...* 패턴을 사용
    final pat = '*$safe*';

    final data = await _retry(() async {
      final sel = _c
          .from(_tRes)
          .select(
            'id,title,filename,original_filename,content_hash,'
            'storage_bucket,storage_path,curriculum_node_id,'
            'mime_type,size_bytes,created_at',
          )
          .inFilter('curriculum_node_id', nodeIds.toList());

      final q = sel
          .or(
            'filename.ilike.$pat,' // resources.filename
            'title.ilike.$pat,' // resources.title
            'resource_filename.ilike.$pat,' // lesson_resource_links.resource_filename
            'resource_title.ilike.$pat,' // lesson_resource_links.resource_title
            'original_filename.ilike.$pat', // lesson_attachments.original_filename
          )
          .order('original_filename', ascending: true, nullsFirst: false)
          .order('filename', ascending: true, nullsFirst: false)
          .order('created_at', ascending: false)
          .limit(300);

      return await q;
    });


    return _mapList(data);
  }

}
