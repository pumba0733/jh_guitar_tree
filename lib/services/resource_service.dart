// lib/services/resource_service.dart
// v1.66.4 | 리소스 키 유니크화 + 레거시 경로 폴백 + 누락 메서드 유지
// - storagePath: yyyy-MM/{nodeSeg}/{shortId}_{safeName} (항상 유니크)
// - FileOptions.upsert=false (덮어쓰기 방지)
// - signedUrl(): 레거시(…/{safe}/{filename}) 폴백 시도

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/resource.dart';

class ResourceService {
  final SupabaseClient _c = Supabase.instance.client;

  /// 서버 SQL과 맞춘 기본 버킷(공유 원본 1벌)
  static const String bucket = 'curriculum';
  static const String _tResources = 'resources';

  // ===== 재시도 유틸 =====
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
        final retry = shouldRetry?.call(e) ?? _defaultShouldRetry(e);
        if (!retry || attempt >= maxAttempts) rethrow;
      }
      if (attempt < maxAttempts) {
        final wait = baseDelay * (1 << (attempt - 1));
        await Future.delayed(wait);
      }
    }
    throw lastError ?? StateError('네트워크 오류');
  }

  bool _defaultShouldRetry(Object e) {
    final s = e.toString();
    return e is SocketException ||
        e is HttpException ||
        e is TimeoutException ||
        s.contains('ENETUNREACH') ||
        s.contains('Connection closed') ||
        s.contains('temporarily unavailable') ||
        s.contains('503') ||
        s.contains('502') ||
        s.contains('429');
  }

  bool _isNotFound(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('404') ||
        s.contains('not found') ||
        s.contains('no such key') ||
        s.contains('no such file');
  }

  // ===== Key/표시명 정규화 =====
  String _keySafeName(String raw) {
    final ext = p.extension(raw);
    var base = p.basenameWithoutExtension(raw);
    base = base.replaceAll(RegExp(r'[\/\\\x00-\x1F]'), '_');
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    base = base.replaceAll(RegExp(r'_+'), '_').trim();
    if (base.isEmpty) {
      base = DateTime.now().millisecondsSinceEpoch.toString();
    }
    var safeExt = ext.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (safeExt.length > 10) safeExt = safeExt.substring(0, 10);
    return '$base$safeExt';
  }

  String _displaySafeName(String raw) {
    final ext = p.extension(raw);
    final base = p.basenameWithoutExtension(raw);
    final sanitizedBase = base
        .replaceAll(RegExp(r'[\/\\\x00-\x1F]'), '_')
        .trim();
    final finalBase = sanitizedBase.isEmpty
        ? DateTime.now().millisecondsSinceEpoch.toString()
        : sanitizedBase;
    return '$finalBase$ext';
  }

  // 충돌 방지를 위한 짧은 ID (가독성+유니크)
  String _shortId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rnd = Random().nextInt(1 << 32).toRadixString(36);
    final s = ts + rnd;
    return s.substring(s.length - 10); // 10자
  }

  // ===== Helpers (DB 매핑) =====
  List<Map<String, dynamic>> _asList(dynamic d) =>
      (d as List<dynamic>? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);

  Map<String, dynamic> _one(dynamic row) =>
      Map<String, dynamic>.from(row as Map);

  Future<bool> _tableExists() async {
    try {
      await _c.from(_tResources).select('id').limit(1);
      return true;
    } catch (e) {
      final s = e.toString();
      if (s.contains('42P01') ||
          (s.contains('relation') && s.contains('does not exist'))) {
        return false;
      }
      return true;
    }
  }

  Future<String> ensureUploadsNode() async {
    // 1) code='uploads_auto' 조회
    try {
      final sel = await _retry(
        () => _c
            .from('curriculum_nodes')
            .select('id')
            .eq('code', 'uploads_auto')
            .limit(1),
      );
      final list = _asList(sel);
      if (list.isNotEmpty) return list.first['id'].toString();
    } catch (_) {
      // 컬럼/뷰 준비 전 등 예외는 아래 insert 시도로 폴백
    }

    // 2) 없으면 생성 (루트 category, order=9999)
    try {
      final ins = await _retry(
        () => _c
            .from('curriculum_nodes')
            .insert({
              'parent_id': null,
              'type': 'category',
              'title': '📥 업로드(자동)',
              '"order"': 9999, // 주의: 컬럼명이 "order"
              'code': 'uploads_auto',
            })
            .select('id')
            .single(),
      );
      return _one(ins)['id'].toString();
    } catch (e) {
      // 경합 등으로 실패 시 재조회
      final sel = await _retry(
        () => _c
            .from('curriculum_nodes')
            .select('id')
            .eq('code', 'uploads_auto')
            .limit(1),
      );
      final list = _asList(sel);
      if (list.isNotEmpty) return list.first['id'].toString();
      rethrow;
    }
  }

  // ===== Queries (기존) =====
  Future<List<ResourceFile>> listByNode(String nodeId) async {
    if (!await _tableExists()) return const <ResourceFile>[];
    final data = await _retry(
      () => _c
          .from(_tResources)
          .select()
          .eq('curriculum_node_id', nodeId)
          .order('created_at', ascending: false),
    );
    return _asList(data).map(ResourceFile.fromMap).toList();
  }

  // ===== 신규: 간단 중복 방지(파일명+크기) =====
  Future<ResourceFile?> findDuplicateByNameAndSize({
    required String filename,
    required int size,
  }) async {
    if (!await _tableExists()) return null;
    try {
      final rows = await _retry(
        () => _c
            .from(_tResources)
            .select()
            .eq('filename', filename)
            .eq('size_bytes', size)
            .limit(1),
      );
      final list = _asList(rows);
      if (list.isEmpty) return null;
      return ResourceFile.fromMap(list.first);
    } catch (_) {
      return null;
    }
  }

  // ===== Insert (기존: node 필수) =====
  Future<ResourceFile> insertRow({
    required String nodeId,
    required String filename,
    required String storagePath,
    String? title,
    String? mimeType,
    int? sizeBytes,
    String storageBucket = bucket,
  }) async {
    final payload = <String, dynamic>{
      'curriculum_node_id': nodeId,
      if (title != null) 'title': title,
      'filename': filename,
      if (mimeType != null) 'mime_type': mimeType,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      'storage_bucket': storageBucket,
      'storage_path': storagePath,
    };
    final ins = await _retry(
      () => _c.from(_tResources).insert(payload).select().single(),
    );
    return ResourceFile.fromMap(_one(ins));
  }

  // ===== 신규: Insert (nodeId 선택) =====
  Future<ResourceFile> insertRowGeneric({
    String? nodeId,
    required String filename,
    required String storagePath,
    String? title,
    String? mimeType,
    int? sizeBytes,
    String storageBucket = bucket,
  }) async {
    final payload = <String, dynamic>{
      if (nodeId != null) 'curriculum_node_id': nodeId,
      if (title != null) 'title': title,
      'filename': filename,
      if (mimeType != null) 'mime_type': mimeType,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      'storage_bucket': storageBucket,
      'storage_path': storagePath,
    };
    final ins = await _retry(
      () => _c.from(_tResources).insert(payload).select().single(),
    );
    return ResourceFile.fromMap(_one(ins));
  }

  // ===== Upload (기존: node 필수) =====
  Future<ResourceFile> uploadForNode({
    required String nodeId,
    required String filename,
    Uint8List? bytes,
    String? filePath,
    String? mimeType,
    int? sizeBytes,
    String storageBucket = bucket,
  }) async {
    if ((bytes == null || bytes.isEmpty) &&
        (filePath == null || filePath.isEmpty)) {
      throw ArgumentError('uploadForNode: bytes 또는 filePath 중 하나는 필요합니다.');
    }
    if (!await _tableExists()) {
      throw StateError('resources 테이블이 아직 준비되지 않았습니다. SQL Δ 필요.');
    }

    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');

    final baseOriginal = p.basename(filename);
    final safeKeyName = _keySafeName(baseOriginal);
    final displayName = _displaySafeName(baseOriginal);

    final nodeSeg = nodeId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final storagePath = '$y-$m/$nodeSeg/${_shortId()}_$safeKeyName';

    final resolvedMime =
        mimeType ?? lookupMimeType(baseOriginal) ?? 'application/octet-stream';

    final store = _c.storage.from(storageBucket);
    final opts = FileOptions(
      upsert: false, // 덮어쓰기 방지
      contentType: resolvedMime,
      cacheControl: '3600',
    );

    int? finalSize = sizeBytes;

    if (bytes != null && bytes.isNotEmpty) {
      final tmpDir = await Directory.systemTemp.createTemp('gt_upload_');
      final tmpFile = File(p.join(tmpDir.path, safeKeyName));
      await tmpFile.writeAsBytes(bytes, flush: true);
      try {
        finalSize ??= await tmpFile.length();
        await _retry(
          () => store.upload(storagePath, tmpFile, fileOptions: opts),
        );
      } finally {
        try {
          await tmpFile.delete();
        } catch (_) {}
        try {
          await tmpDir.delete(recursive: true);
        } catch (_) {}
      }
    } else {
      final f = File(filePath!);
      finalSize ??= await f.length();
      await _retry(() => store.upload(storagePath, f, fileOptions: opts));
    }

    return insertRow(
      nodeId: nodeId,
      filename: displayName,
      storagePath: storagePath,
      mimeType: resolvedMime,
      sizeBytes: finalSize,
      storageBucket: storageBucket,
    );
  }

  // ===== 신규: Upload (nodeId 선택/없음) =====
  Future<ResourceFile> uploadGeneric({
    String? nodeId,
    required String filename,
    Uint8List? bytes,
    String? filePath,
    String? mimeType,
    int? sizeBytes,
    String storageBucket = bucket,
  }) async {
    // [ADD] nodeId 없으면 업로드용 숨김 노드 보장
    final String effectiveNodeId = nodeId ?? await ensureUploadsNode();
    if ((bytes == null || bytes.isEmpty) &&
        (filePath == null || filePath.isEmpty)) {
      throw ArgumentError('uploadGeneric: bytes 또는 filePath 중 하나는 필요합니다.');
    }
    if (!await _tableExists()) {
      throw StateError('resources 테이블이 아직 준비되지 않았습니다.');
    }

    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');

    final baseOriginal = p.basename(filename);
    final safeKeyName = _keySafeName(baseOriginal);
    final displayName = _displaySafeName(baseOriginal);

    final nodeSeg = effectiveNodeId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final storagePath = '$y-$m/$nodeSeg/${_shortId()}_$safeKeyName';

    final resolvedMime =
        mimeType ?? lookupMimeType(baseOriginal) ?? 'application/octet-stream';

    final store = _c.storage.from(storageBucket);
    final opts = FileOptions(
      upsert: false, // 덮어쓰기 방지
      contentType: resolvedMime,
      cacheControl: '3600',
    );

    int? finalSize = sizeBytes;

    if (bytes != null && bytes.isNotEmpty) {
      final tmpDir = await Directory.systemTemp.createTemp('gt_upload_');
      final tmpFile = File(p.join(tmpDir.path, safeKeyName));
      await tmpFile.writeAsBytes(bytes, flush: true);
      try {
        finalSize ??= await tmpFile.length();
        await _retry(
          () => store.upload(storagePath, tmpFile, fileOptions: opts),
        );
      } finally {
        try {
          await tmpFile.delete();
        } catch (_) {}
        try {
          await tmpDir.delete(recursive: true);
        } catch (_) {}
      }
    } else {
      final f = File(filePath!);
      finalSize ??= await f.length();
      await _retry(() => store.upload(storagePath, f, fileOptions: opts));
    }

    // 중복 방지(최소): 파일명+크기 동일시 기존 row 재사용
    if (finalSize != null) {
      final dup = await findDuplicateByNameAndSize(
        filename: displayName,
        size: finalSize!,
      );
      if (dup != null) return dup;
    }

    return insertRowGeneric(
      nodeId: effectiveNodeId, // ← NOT NULL 보장
      filename: displayName,
      storagePath: storagePath,
      mimeType: resolvedMime,
      sizeBytes: finalSize,
      storageBucket: storageBucket,
    );
  }

  /// 로컬 경로에서 리소스로 업로드 (nodeId 옵션) — file_service.dart가 사용
  Future<ResourceFile> uploadFromLocalPathAsResource({
    required String localPath,
    String? originalFilename,
    String? nodeId, // null 허용
  }) async {
    final f = File(localPath);
    final exists = await f.exists();
    if (!exists) {
      throw ArgumentError('파일을 찾을 수 없습니다: $localPath');
    }
    final size = await f.length();
    final name = originalFilename ?? p.basename(localPath);
    return uploadGeneric(
      nodeId: nodeId,
      filename: name,
      filePath: localPath,
      sizeBytes: size,
      storageBucket: bucket,
    );
  }

  // ===== Delete =====
  Future<void> delete(ResourceFile r) async {
    try {
      await _retry(
        () => _c.storage.from(r.storageBucket).remove([r.storagePath]),
      );
    } catch (e) {
      if (!_isNotFound(e)) rethrow;
    }
    await _retry(() => _c.from(_tResources).delete().eq('id', r.id));
  }

  // ===== Signed URL =====
  Future<String> signedUrl(
    ResourceFile r, {
    Duration ttl = const Duration(hours: 24),
  }) async {
    final store = _c.storage.from(r.storageBucket);
    final primary = r.storagePath;

    // 1차: 현재 storage_path 그대로 서명
    try {
      return await _retry(() => store.createSignedUrl(primary, ttl.inSeconds));
    } catch (e) {
      // 404/키없음 같은 경우에만 레거시 폴백 시도
      if (!_isNotFound(e)) {
        rethrow;
      }
      // 2차(레거시): storage_path + '/' + filename 시도
      final legacy = '$primary/${r.filename}';
      try {
        return await _retry(() => store.createSignedUrl(legacy, ttl.inSeconds));
      } catch (_) {
        rethrow;
      }
    }
  }
}
