// lib/services/curriculum_service.dart
// v1.45.0 | 커리큘럼 서비스 - v1.45 가시 트리 RPC 우선 사용 + 루트파일 금지 가드 유지
// - listNodes(): rpc.list_visible_curriculum_tree()가 있으면 이를 사용(권한/가시성 반영)
//   * RPC 미존재/오류 시 자동 폴백하여 테이블 직접 조회(정렬 동일)
// - createNode/updateNode: 루트(parent_id==null)에서 file 금지 가드 유지
// - 기타 API 시그니처/동작은 v1.44와 호환

import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException, HttpException;
import 'package:supabase_flutter/supabase_flutter.dart';

class CurriculumService {
  final SupabaseClient _c = Supabase.instance.client;

  // ---------- Table / RPC names ----------
  static const _tNodes = 'curriculum_nodes';
  static const _tAssign = 'curriculum_assignments';
  static const _rpcVisibleTree = 'list_visible_curriculum_tree';

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

  // 재시도 유틸(네트워크/일시 오류 흡수)
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

  // ========== Reads ==========
  /// v1.45: 교사/관리자 가시성 반영된 전체 노드 목록
  /// - 가능하면 RPC 사용, 아니면 테이블 폴백
  Future<List<Map<String, dynamic>>> listNodes() async {
    // 먼저 RPC를 한번 시도해보고, 성공하면 캐시 플래그 세팅
    if (_hasVisibleTreeRpc != false) {
      try {
        final data = await _retry(() => _c.rpc(_rpcVisibleTree));
        final list = _mapList(data);
        _hasVisibleTreeRpc = true;
        return list;
      } catch (e) {
        // 함수 미존재/권한/기타 오류 시 폴백 후 다음번까지 캐시
        final msg = e.toString().toLowerCase();
        if (msg.contains('does not exist') ||
            msg.contains('not exist') ||
            msg.contains('42883')) {
          _hasVisibleTreeRpc = false;
        }
        // 폴백 계속 진행
      }
    }
    // 폴백: 테이블 직접 조회 (parent/order/created_at)
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

  /// 부모 기준 자식 목록(폴백용/세부 조회용). 가시성은 서버 RLS에 의존.
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

  /// 단일 노드
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
    List<String>? path, // jsonb 배열
    String? filePath, // 텍스트 경로
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
    ); // RLS 차단 시 null
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
    // ✅ 루트파일 금지
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

    // 현재 상태 조회 후 변경될 상태로 가드
    final before = await getNode(id);
    if (before == null) {
      throw StateError('updateNode: 대상 노드를 찾을 수 없습니다. id=$id');
    }
    final newParentId = parentId ?? before['parent_id'];
    final newType = (type ?? before['type'] ?? '').toString();

    // ✅ 루트파일 금지
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

  /// 노드 이동(부모/정렬 변경) — updateNode 경유
  Future<Map<String, dynamic>> moveNode({
    required String id,
    String? newParentId,
    int? newOrder,
  }) {
    return updateNode(id: id, parentId: newParentId, order: newOrder);
  }

  /// 노드 삭제
  Future<void> deleteNode(String id, {bool recursive = false}) async {
    if (!recursive) {
      await _retry(() => _c.from(_tNodes).delete().eq('id', id));
      return;
    }
    // 안전 DFS: 자식 → 부모
    final children = await listNodesByParent(id);
    for (final ch in children) {
      final cid = (ch['id'] ?? '').toString();
      if (cid.isEmpty) continue;
      await deleteNode(cid, recursive: true);
    }
    await _retry(() => _c.from(_tNodes).delete().eq('id', id));
  }
}
