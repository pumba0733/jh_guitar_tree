// lib/services/curriculum_service.dart
// v1.46.2 | 커리큘럼 서비스
// - NEW: buildBrowserUrl(nodeId), openInBrowser(nodeId)
// - listNodes(): RPC 우선 + 폴백 유지
// - 루트파일 금지 가드 유지

import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException, HttpException;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart'; // ⬅️ 외부/앱 스킴 열기

class CurriculumService {
  final SupabaseClient _c = Supabase.instance.client;

  // ---------- Table / RPC names ----------
  static const _tNodes = 'curriculum_nodes';
  static const _tAssign = 'curriculum_assignments';
  static const _rpcVisibleTree = 'list_visible_curriculum_tree';

  // 🔗 딥링크 베이스(필요 시 .env/상수로 이동 가능)
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

  // 재시도 유틸
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

  // ========== NEW: Browser Deep Link ==========
  /// 커리큘럼 브라우저에서 특정 노드를 열기 위한 URL을 만든다.
  /// - preferAppScheme=true 이면 앱 스킴(guitartree://) 우선
  /// - 아니면 웹 URL(https://...) 반환
  String buildBrowserUrl(String nodeId, {bool preferAppScheme = true}) {
    final id = nodeId.trim();
    if (id.isEmpty) {
      throw ArgumentError('buildBrowserUrl: nodeId가 비어있습니다.');
    }
    final base = preferAppScheme ? _appDeepLinkBase : _webDeepLinkBase;
    return '$base?node=$id';
  }

  /// 위 URL을 외부 앱/브라우저로 연다.
  Future<void> openInBrowser(
    String nodeId, {
    bool preferAppScheme = true,
  }) async {
    final url = buildBrowserUrl(nodeId, preferAppScheme: preferAppScheme);
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      throw StateError('브라우저/앱으로 열기 실패: $url');
    }
  }

  // ========== Reads ==========
  Future<List<Map<String, dynamic>>> listNodes() async {
    if (_hasVisibleTreeRpc != false) {
      try {
        final data = await _retry(() => _c.rpc(_rpcVisibleTree));
        final list = _mapList(data);
        _hasVisibleTreeRpc = true;
        return list;
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

  // ========== Assignments ==========
  Future<List<Map<String, dynamic>>> listAssignmentsByStudent(
    String studentId,
  ) async {
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

  // ========== Nodes CRUD ==========
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
}
