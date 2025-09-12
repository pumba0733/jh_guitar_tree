// lib/services/curriculum_service.dart
// v1.44.0 | 커리큘럼 서비스 - 루트파일 금지 가드 추가
// - 정책 반영: 최상위(parent_id == null)에는 category만 허용, file 금지
// - createNode / updateNode에서 루트파일 생성/변경 시도 차단
// - 나머지 정렬/배정/삭제 로직은 v1.43.1 유지

import 'package:supabase_flutter/supabase_flutter.dart';

class CurriculumService {
  final SupabaseClient _c = Supabase.instance.client;

  // ---------- Table names ----------
  static const _tNodes = 'curriculum_nodes';
  static const _tAssign = 'curriculum_assignments';

  // ---------- Helpers ----------
  List<Map<String, dynamic>> _mapList(dynamic data) {
    final list = (data as List<dynamic>? ?? const []);
    return list
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
  }

  Map<String, dynamic> _mapOne(dynamic row) =>
      Map<String, dynamic>.from(row as Map);

  // ---------- Policy Guards ----------
  bool _isRoot(String? parentId) => parentId == null;
  void _ensureNotRootFile({required String? parentId, required String type}) {
    if (_isRoot(parentId) && type.trim() == 'file') {
      throw StateError('루트(depth 0)에는 file 타입을 만들 수 없습니다. (category만 허용)');
    }
  }

  // ========== Reads ==========
  /// 모든 노드 (parent/order/created_at 순)
  Future<List<Map<String, dynamic>>> listNodes() async {
    final data = await _c
        .from(_tNodes)
        .select()
        .order('parent_id', ascending: true, nullsFirst: true)
        .order('order', ascending: true)
        .order('created_at', ascending: true);
    return _mapList(data);
  }

  /// 부모 기준 자식 목록
  Future<List<Map<String, dynamic>>> listNodesByParent(String? parentId) async {
    final base = _c.from(_tNodes).select();
    final filtered = parentId == null
        ? base.filter('parent_id', 'is', null)
        : base.eq('parent_id', parentId);
    final data = await filtered
        .order('order', ascending: true)
        .order('created_at', ascending: true);
    return _mapList(data);
  }

  /// 단일 노드
  Future<Map<String, dynamic>?> getNode(String id) async {
    final data = await _c.from(_tNodes).select().eq('id', id).maybeSingle();
    if (data == null) return null;
    return _mapOne(data);
  }

  // ========== Assignments ==========
  /// 특정 학생의 배정 목록
  Future<List<Map<String, dynamic>>> listAssignmentsByStudent(
    String studentId,
  ) async {
    final data = await _c.from(_tAssign).select().eq('student_id', studentId);
    return _mapList(data);
  }

  /// 특정 노드에 배정된 학생 목록
  Future<List<Map<String, dynamic>>> listAssignmentsByNode(
    String nodeId,
  ) async {
    final data = await _c
        .from(_tAssign)
        .select()
        .eq('curriculum_node_id', nodeId);
    return _mapList(data);
  }

  /// 학생 1명에게 노드 배정 (중복 안전)
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

    final upserted = await _c
        .from(_tAssign)
        .upsert(payload, onConflict: 'student_id,curriculum_node_id')
        .select()
        .maybeSingle(); // RLS 차단 시 null
    return upserted == null ? null : _mapOne(upserted);
  }

  /// 여러 학생에게 같은 노드 일괄 배정
  Future<int> assignNodeToStudents({
    required List<String> studentIds,
    required String nodeId,
  }) async {
    if (studentIds.isEmpty) return 0;
    final rows = studentIds
        .where((s) => s.trim().isNotEmpty)
        .map((s) => {'student_id': s.trim(), 'curriculum_node_id': nodeId})
        .toList(growable: false);

    final res = await _c
        .from(_tAssign)
        .upsert(rows, onConflict: 'student_id,curriculum_node_id')
        .select();
    return (res as List).length;
  }

  /// 배정 해제
  Future<void> unassignNodeFromStudent({
    required String studentId,
    required String nodeId,
  }) async {
    await _c
        .from(_tAssign)
        .delete()
        .eq('student_id', studentId)
        .eq('curriculum_node_id', nodeId);
  }

  // ========== Nodes CRUD ==========
  /// 노드 생성
  ///
  /// [type]: 'category' | 'file' (기본 category)
  /// [order]는 스키마에 컬럼 있을 때만 포함
  Future<Map<String, dynamic>> createNode({
    String? parentId,
    String type = 'category',
    required String title,
    String? fileUrl,
    int? order,
    Map<String, dynamic>? extra, // 스키마 확장 대비(예: difficulty 등)
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
    final inserted = await _c.from(_tNodes).insert(payload).select().single();
    return _mapOne(inserted);
  }

  /// 노드 수정
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

    // ✅ 루트파일 금지(현재 상태 + 변경될 상태 모두 고려)
    // 현재 노드 상태 조회
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

    final updated = await _c
        .from(_tNodes)
        .update(payload)
        .eq('id', id)
        .select()
        .single();
    return _mapOne(updated);
  }

  /// 노드 이동(부모/정렬 변경)
  Future<Map<String, dynamic>> moveNode({
    required String id,
    String? newParentId,
    int? newOrder,
  }) {
    // move도 updateNode를 경유하여 동일 가드 적용
    return updateNode(id: id, parentId: newParentId, order: newOrder);
  }

  /// 노드 삭제
  /// [recursive]=true면 하위 먼저 삭제 후 자신 삭제(DFS)
  Future<void> deleteNode(String id, {bool recursive = false}) async {
    if (!recursive) {
      await _c.from(_tNodes).delete().eq('id', id);
      return;
    }
    // 안전 DFS: 자식 → 부모
    final children = await listNodesByParent(id);
    for (final ch in children) {
      final cid = (ch['id'] ?? '').toString();
      if (cid.isEmpty) continue;
      await deleteNode(cid, recursive: true);
    }
    await _c.from(_tNodes).delete().eq('id', id);
  }
}
