// lib/services/resource_service.dart
// v1.67.2-lintfix | ASCII-safe key + (NEW) moveResourceToNode()
// - storagePath: yyyy-MM/{nodeSeg}/{safeBase}__{sha1-12}{ext}
// - signedUrl 레거시 폴백 유지
// - NEW: moveResourceToNode(resourceId, newNodeId)
// - Lint fixes:
//   * string interpolation에서 필요한 곳만 {} 유지 (safeBase, h12 앞뒤에 '_'가 붙음)
//   * finalSize 비nullable로 정리하여 null 비교/! 제거

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/resource.dart';

class ResourceService {
  final SupabaseClient _c = Supabase.instance.client;

  /// 서버 SQL과 맞춘 기본 버킷(공유 원본 1벌)
  static const String bucket = 'curriculum';
  static const String _tResources = 'resources';

  // ---------- 재시도 유틸 ----------
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

  // ---------- 테이블/행 유틸 ----------
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

  // ---------- ASCII-safe 키 생성기 ----------
  String _toAsciiSafe(String s) {
    final replaced = s
        .replaceAll(RegExp(r'[\/\\]'), '-')
        .replaceAll(RegExp(r'\s+'), '_');
    final buf = StringBuffer();
    for (final ch in replaced.runes) {
      if ((ch >= 0x30 && ch <= 0x39) ||
          (ch >= 0x41 && ch <= 0x5A) ||
          (ch >= 0x61 && ch <= 0x7A) ||
          ch == 0x2D ||
          ch == 0x5F ||
          ch == 0x2E) {
        buf.writeCharCode(ch);
      } else {
        buf.write('_');
      }
    }
    final compact = buf
        .toString()
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return compact.isEmpty ? 'file' : compact;
  }

  String _buildAsciiStorageKey({
    required String originalFilename,
    required String nodeSeg,
    required Uint8List bytes,
    DateTime? now,
  }) {
    final dt = now ?? DateTime.now();
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');

    final ext = p.extension(originalFilename);
    final base = p.basenameWithoutExtension(originalFilename);
    final safeBase = _toAsciiSafe(base);
    final h12 = crypto.sha1.convert(bytes).toString().substring(0, 12);

    // NOTE: 여기서는 {}가 필요함 (변수 뒤에 '_' 문자가 이어짐)
    return '$y-$m/$nodeSeg/${safeBase}__$h12$ext';
  }

  // ---------- 업로드용 기본 노드 보장 ----------
  Future<String> ensureUploadsNode() async {
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
    } catch (_) {}

    try {
      final ins = await _retry(
        () => _c
            .from('curriculum_nodes')
            .insert({
              'parent_id': null,
              'type': 'category',
              'title': '📥 업로드(자동)',
              '"order"': 9999,
              'code': 'uploads_auto',
            })
            .select('id')
            .single(),
      );
      return _one(ins)['id'].toString();
    } catch (e) {
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

  // ---------- 조회 ----------
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

  // ---------- 간단 중복 방지(파일명+크기) ----------
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

  // ---------- Insert ----------
  Future<ResourceFile> insertRow({
    required String nodeId,
    required String filename,
    required String storagePath,
    String? title,
    String? mimeType,
    int? sizeBytes,
    String? originalFilename,
    String? contentHash,
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
      if (originalFilename != null) 'original_filename': originalFilename,
      if (contentHash != null) 'content_hash': contentHash,
    };
    final ins = await _retry(
      () => _c.from(_tResources).insert(payload).select().single(),
    );
    return ResourceFile.fromMap(_one(ins));
  }

  Future<ResourceFile> insertRowGeneric({
    String? nodeId,
    required String filename,
    required String storagePath,
    String? title,
    String? mimeType,
    int? sizeBytes,
    String? originalFilename,
    String? contentHash,
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
      if (originalFilename != null) 'original_filename': originalFilename,
      if (contentHash != null) 'content_hash': contentHash,
    };
    final ins = await _retry(
      () => _c.from(_tResources).insert(payload).select().single(),
    );
    return ResourceFile.fromMap(_one(ins));
  }

  // ---------- Upload (node 필수) ----------
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

    final baseOriginal = p.basename(filename);
    final resolvedMime =
        mimeType ?? lookupMimeType(baseOriginal) ?? 'application/octet-stream';

    // 파일 바이트 & 사이즈 계산
    Uint8List fileBytes;
    if (bytes != null && bytes.isNotEmpty) {
      fileBytes = bytes;
    } else {
      final f = File(filePath!);
      fileBytes = await f.readAsBytes();
    }
    final int finalSize = sizeBytes ?? fileBytes.lengthInBytes;
    final contentHash = crypto.sha1.convert(fileBytes).toString();

    final nodeSeg = nodeId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final storagePath = _buildAsciiStorageKey(
      originalFilename: baseOriginal,
      nodeSeg: nodeSeg,
      bytes: fileBytes,
    );

    final store = _c.storage.from(storageBucket);
    final opts = FileOptions(
      upsert: false,
      contentType: resolvedMime,
      cacheControl: '3600',
    );

    try {
      if (bytes != null && bytes.isNotEmpty) {
        final tmpDir = await Directory.systemTemp.createTemp('gt_upload_');
        final tmpFile = File(p.join(tmpDir.path, baseOriginal));
        await tmpFile.writeAsBytes(fileBytes, flush: true);
        try {
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
        await _retry(
          () => store.uploadBinary(storagePath, fileBytes, fileOptions: opts),
        );
      }
    } catch (e) {
      final s = e.toString().toLowerCase();
      final is409 =
          s.contains('409') ||
          s.contains('already exists') ||
          s.contains('duplicate');
      if (!is409) rethrow;

      final existed = await findByStorageKey(
        storageBucket: storageBucket,
        storagePath: storagePath,
      );
      if (existed != null) return existed;

      return insertRow(
        nodeId: nodeId,
        filename: baseOriginal,
        storagePath: storagePath,
        mimeType: resolvedMime,
        sizeBytes: finalSize,
        originalFilename: baseOriginal,
        contentHash: contentHash,
        storageBucket: storageBucket,
      );
    }

    return insertRow(
      nodeId: nodeId,
      filename: baseOriginal,
      storagePath: storagePath,
      mimeType: resolvedMime,
      sizeBytes: finalSize,
      originalFilename: baseOriginal,
      contentHash: contentHash,
      storageBucket: storageBucket,
    );
  }

  // ---------- Upload (nodeId 옵션) ----------
  Future<ResourceFile> uploadGeneric({
    String? nodeId,
    required String filename,
    Uint8List? bytes,
    String? filePath,
    String? mimeType,
    int? sizeBytes,
    String storageBucket = bucket,
  }) async {
    final String effectiveNodeId = nodeId ?? await ensureUploadsNode();

    if ((bytes == null || bytes.isEmpty) &&
        (filePath == null || filePath.isEmpty)) {
      throw ArgumentError('uploadGeneric: bytes 또는 filePath 중 하나는 필요합니다.');
    }
    if (!await _tableExists()) {
      throw StateError('resources 테이블이 아직 준비되지 않았습니다.');
    }

    final baseOriginal = p.basename(filename);
    final resolvedMime =
        mimeType ?? lookupMimeType(baseOriginal) ?? 'application/octet-stream';

    // 파일 바이트 & 사이즈 계산 (비nullable)
    Uint8List fileBytes;
    if (bytes != null && bytes.isNotEmpty) {
      fileBytes = bytes;
    } else {
      final f = File(filePath!);
      fileBytes = await f.readAsBytes();
    }
    final int finalSize = sizeBytes ?? fileBytes.lengthInBytes;
    final contentHash = crypto.sha1.convert(fileBytes).toString();

    final nodeSeg = effectiveNodeId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final storagePath = _buildAsciiStorageKey(
      originalFilename: baseOriginal,
      nodeSeg: nodeSeg,
      bytes: fileBytes,
    );

    final store = _c.storage.from(storageBucket);
    final opts = FileOptions(
      upsert: false,
      contentType: resolvedMime,
      cacheControl: '3600',
    );

    // 중복 검사 (이미 비nullable이므로 불필요한 null 비교 제거)
    final dup = await findDuplicateByNameAndSize(
      filename: baseOriginal,
      size: finalSize,
    );
    if (dup != null) return dup;

    try {
      if (bytes != null && bytes.isNotEmpty) {
        final tmpDir = await Directory.systemTemp.createTemp('gt_upload_');
        final tmpFile = File(p.join(tmpDir.path, baseOriginal));
        await tmpFile.writeAsBytes(fileBytes, flush: true);
        try {
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
        await _retry(
          () => store.uploadBinary(storagePath, fileBytes, fileOptions: opts),
        );
      }
    } catch (e) {
      final s = e.toString().toLowerCase();
      final is409 =
          s.contains('409') ||
          s.contains('already exists') ||
          s.contains('duplicate');
      if (!is409) rethrow;

      final existed = await findByStorageKey(
        storageBucket: storageBucket,
        storagePath: storagePath,
      );
      if (existed != null) return existed;

      return insertRowGeneric(
        nodeId: effectiveNodeId,
        filename: baseOriginal,
        storagePath: storagePath,
        mimeType: resolvedMime,
        sizeBytes: finalSize,
        originalFilename: baseOriginal,
        contentHash: contentHash,
        storageBucket: storageBucket,
      );
    }

    return insertRowGeneric(
      nodeId: effectiveNodeId,
      filename: baseOriginal,
      storagePath: storagePath,
      mimeType: resolvedMime,
      sizeBytes: finalSize,
      originalFilename: baseOriginal,
      contentHash: contentHash,
      storageBucket: storageBucket,
    );
  }

  /// 로컬 경로에서 리소스로 업로드 (nodeId 옵션) — file_service.dart가 사용
  Future<ResourceFile> uploadFromLocalPathAsResource({
    required String localPath,
    String? originalFilename,
    String? nodeId,
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

  // ---------- Delete (Storage → DB 순) ----------
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

  // ---------- Signed URL (레거시 폴백 유지) ----------
  Future<String> signedUrl(
    ResourceFile r, {
    Duration ttl = const Duration(hours: 24),
  }) async {
    final store = _c.storage.from(r.storageBucket);
    final primary = r.storagePath;

    try {
      return await _retry(() => store.createSignedUrl(primary, ttl.inSeconds));
    } catch (e) {
      if (!_isNotFound(e)) rethrow;
      final legacy = '$primary/${r.filename}';
      return await _retry(() => store.createSignedUrl(legacy, ttl.inSeconds));
    }
  }

  // ---------- 키로 조회 ----------
  Future<ResourceFile?> findByStorageKey({
    required String storageBucket,
    required String storagePath,
  }) async {
    if (!await _tableExists()) return null;
    try {
      final rows = await _retry(
        () => _c
            .from(_tResources)
            .select()
            .eq('storage_bucket', storageBucket)
            .eq('storage_path', storagePath)
            .limit(1),
      );
      final list = _asList(rows);
      if (list.isEmpty) return null;
      return ResourceFile.fromMap(list.first);
    } catch (_) {
      return null;
    }
  }

  // ---------- (NEW) 매핑 변경 ----------
  Future<void> moveResourceToNode({
    required String resourceId,
    required String newNodeId,
  }) async {
    if (!await _tableExists()) {
      throw StateError('resources 테이블이 아직 준비되지 않았습니다.');
    }
    await _retry(
      () => _c
          .from(_tResources)
          .update({'curriculum_node_id': newNodeId})
          .eq('id', resourceId),
    );
  }

  // (옵션) 여러 개 한번에 이동
  Future<void> moveManyResourcesToNode({
    required List<String> resourceIds,
    required String newNodeId,
  }) async {
    if (resourceIds.isEmpty) return;
    if (!await _tableExists()) {
      throw StateError('resources 테이블이 아직 준비되지 않았습니다.');
    }
    await _retry(
      () => _c
          .from(_tResources)
          .update({'curriculum_node_id': newNodeId})
          .inFilter('id', resourceIds),
    );
  }
}
