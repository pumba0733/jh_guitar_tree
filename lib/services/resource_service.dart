// lib/services/resource_service.dart
// v1.45.3 | 업/삭 안정화: 404 삭제 무시 + sizeBytes 보강 + 디버그로그
// - 삭제 시 스토리지 404/NoSuchKey는 무시하고 DB만 정리(과거 경로 불일치 청소)
// - 업로드 sizeBytes null이면 자동 계산
// - 업/삭 로그 추가로 원인 추적 용이
// - 기존: 버킷 기본값 'curriculum' + ASCII-safe key + 임시파일 업로드 유지

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/resource.dart';

class ResourceService {
  final SupabaseClient _c = Supabase.instance.client;

  /// 서버 SQL과 맞춘 기본 버킷
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
    // supabase storage remove: 404 / not found / no such key 패턴 흡수
    return s.contains('404') ||
        s.contains('not found') ||
        s.contains('no such key') ||
        s.contains('no such file');
  }

  // ===== Key/표시명 정규화 =====
  String _keySafeName(String raw) {
    final ext = p.extension(raw); // 원래 확장자(점 포함)
    var base = p.basenameWithoutExtension(raw);

    // 경로문자/제어문자 제거 → 영문/숫자/_/.- 만 허용
    base = base.replaceAll(RegExp(r'[\/\\\x00-\x1F]'), '_');
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    base = base.replaceAll(RegExp(r'_+'), '_').trim();
    if (base.isEmpty) {
      base = DateTime.now().millisecondsSinceEpoch.toString();
    }
    var safeExt = ext.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    if (safeExt.length > 10) safeExt = safeExt.substring(0, 10); // 과도한 확장자 보호
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
      return true; // 권한/기타 오류는 존재로 간주
    }
  }

  // ===== Queries =====
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

  Future<ResourceFile> insertRow({
    required String nodeId,
    required String filename, // UI 표시용(원래 이름 정리)
    required String storagePath, // 실제 업로드 key
    String? title,
    String? mimeType,
    int? sizeBytes,
    String storageBucket = bucket, // 기본 'curriculum'
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

  // ===== Upload =====
  Future<ResourceFile> uploadForNode({
    required String nodeId,
    required String filename, // 원본 파일명
    Uint8List? bytes,
    String? filePath,
    String? mimeType,
    int? sizeBytes,
    String storageBucket = bucket, // 기본 'curriculum'
  }) async {
    if ((bytes == null || bytes.isEmpty) &&
        (filePath == null || filePath.isEmpty)) {
      throw ArgumentError('uploadForNode: bytes 또는 filePath 중 하나는 필요합니다.');
    }
    if (!await _tableExists()) {
      throw StateError('resources 테이블이 아직 준비되지 않았습니다. SQL Δ 적용 필요.');
    }

    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');

    final baseOriginal = p.basename(filename);
    final safeKeyName = _keySafeName(baseOriginal); // Storage key
    final displayName = _displaySafeName(baseOriginal); // UI 표시용

    final nodeSeg = nodeId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final storagePath = '$y-$m/$nodeSeg/$safeKeyName';

    final resolvedMime =
        mimeType ?? lookupMimeType(baseOriginal) ?? 'application/octet-stream';

    final store = _c.storage.from(storageBucket);
    final opts = FileOptions(
      upsert: true,
      contentType: resolvedMime,
      cacheControl: '3600',
    );

    int? finalSize = sizeBytes;

    // ---- 실제 업로드 ----
    if (bytes != null && bytes.isNotEmpty) {
      final tmpDir = await Directory.systemTemp.createTemp('gt_upload_');
      final tmpFile = File(p.join(tmpDir.path, safeKeyName));
      await tmpFile.writeAsBytes(bytes, flush: true);
      try {
        finalSize ??= await tmpFile.length();
        print(
          '[UP] bucket=$storageBucket path=$storagePath (from=bytes size=$finalSize mime=$resolvedMime)',
        );
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
      print(
        '[UP] bucket=$storageBucket path=$storagePath (from=file size=$finalSize mime=$resolvedMime)',
      );
      await _retry(() => store.upload(storagePath, f, fileOptions: opts));
    }

    return insertRow(
      nodeId: nodeId,
      filename: displayName, // 한글표시 OK
      storagePath: storagePath, // ASCII-safe 키
      mimeType: resolvedMime,
      sizeBytes: finalSize,
      storageBucket: storageBucket,
    );
  }

  // ===== Delete =====
  Future<void> delete(ResourceFile r) async {
    // 1) 스토리지 삭제: 404/NoSuchKey는 무시 (과거 경로 불일치 청소용)
    try {
      print('[DEL] bucket=${r.storageBucket} path=${r.storagePath}');
      await _retry(
        () => _c.storage.from(r.storageBucket).remove([r.storagePath]),
      );
    } catch (e) {
      if (_isNotFound(e)) {
        print(
          '[DEL] storage not found, continue DB cleanup: ${r.storageBucket}/${r.storagePath}',
        );
      } else {
        rethrow;
      }
    }
    // 2) DB 삭제 (항상 시도)
    await _retry(() => _c.from(_tResources).delete().eq('id', r.id));
  }

  // ===== Signed URL =====
  Future<String> signedUrl(
    ResourceFile r, {
    Duration ttl = const Duration(hours: 24),
  }) async {
    try {
      final url = await _retry(
        () => _c.storage
            .from(r.storageBucket)
            .createSignedUrl(r.storagePath, ttl.inSeconds),
      );
      return url;
    } catch (e) {
      throw StateError('서명 URL 생성 실패: ${r.storageBucket}/${r.storagePath}\n$e');
    }
  }
}
