// lib/services/resource_service.dart
// v1.43.1 | 안전 업로드(+정규화) · 재시도 · 서명URL · 스키마 정합
// - Storage object key 안전 정규화(InvalidKey 400 방지)
// - 업로드/삭제/서명URL에 지수적 재시도 + 타임아웃
// - DB에는 "표시용" 원래 이름 저장, Storage에는 정규화된 key 사용
// - SQL 정합: bucket='curriculum'(private 권장), table=public.resources
// - 테이블 미구성 시 업로드 차단(명확 에러), 조회는 빈 리스트 반환

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/resource.dart';

class ResourceService {
  final SupabaseClient _c = Supabase.instance.client;

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
        // fallthrough
      } catch (e) {
        lastError = e;
        final retry = shouldRetry?.call(e) ?? _defaultShouldRetry(e);
        if (!retry || attempt >= maxAttempts) rethrow;
      }
      if (attempt < maxAttempts) {
        final wait = baseDelay * (1 << (attempt - 1)); // 250, 500, 1000...
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

    // 경로/제어문자 제거 → 허용 외 전부 '_'
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
      // 존재하면 정상 응답, 없으면 42P01(Relation does not exist)류 에러
      await _c.from(_tResources).select('id').limit(1);
      return true;
    } catch (e) {
      final s = e.toString();
      // relation not found / undefined table 시 false
      if (s.contains('42P01') ||
          s.contains('relation') && s.contains('does not exist')) {
        return false;
      }
      // 기타 에러(일시 네트워크/권한)는 테이블은 있다고 보고 true
      return true;
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

  // ===== Upload =====
  /// bytes가 있으면 uploadBinary, 없으면 파일 경로로 업로드
  /// - Storage key: _keySafeName()
  /// - DB에는 표시용 파일명(_displaySafeName) 저장
  Future<ResourceFile> uploadForNode({
    required String nodeId,
    required String filename, // 원본 파일명
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

    final store = _c.storage.from(storageBucket);
    final opts = FileOptions(
      upsert: true,
      contentType: mimeType ?? 'application/octet-stream',
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
      mimeType: mimeType,
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
    final url = await _retry(
      () => _c.storage
          .from(r.storageBucket)
          .createSignedUrl(r.storagePath, ttl.inSeconds),
    );
    return url;
    // private 버킷도 접근 가능한 일시적 URL을 반환
  }
}
