// lib/services/resource_service.dart
// v1.45.0 | 버킷 기본값을 서버 정책과 일치('curriculum')로 통일 + 안정 재시도 유지
// - bucket: 'curriculum' (SQL: storage.buckets id='curriculum', private)
// - 업로드/DB 기록/서명 URL 로직은 동일
// - _tableExists: 42P01 등 처리로 안전

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/resource.dart';

class ResourceService {
  final SupabaseClient _c = Supabase.instance.client;

  /// 서버 SQL(v1.44/v1.45)과 맞춘 기본 버킷
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
    required String filename, // 표시용(원래 이름 정리)
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

    if (bytes != null && bytes.isNotEmpty) {
      await _retry(
        () => store.uploadBinary(storagePath, bytes, fileOptions: opts),
      );
    } else {
      await _retry(
        () => store.upload(storagePath, File(filePath!), fileOptions: opts),
      );
    }

    return insertRow(
      nodeId: nodeId,
      filename: displayName, // ← UI 노출(한글 유지)
      storagePath: storagePath,
      mimeType: resolvedMime,
      sizeBytes: sizeBytes,
      storageBucket: storageBucket,
    );
  }

  // ===== Delete =====
  Future<void> delete(ResourceFile r) async {
    await _retry(
      () => _c.storage.from(r.storageBucket).remove([r.storagePath]),
    );
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
