// lib/packages/smart_media_player/sync/sidecar_sync.dart
// v2.0.0 | Sidecar sync (Standalone) — no dependency on PlayerSidecarStorageService
// - Bucket: player_sidecars
// - Path:   player_sidecars/<studentId>/<mediaHash>/current.json
// - Backup: player_sidecars/<studentId>/<mediaHash>/backups/<ISO>.json
//
// LWW: savedAt 기준 최신본 우선 적용

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

/// 사이드카: 로컬/Storage 동기화 (단독 구현)
class SidecarSync {
  SidecarSync._();
  static final SidecarSync instance = SidecarSync._();

  // ====== Storage helpers ======
  static const String _bucket = 'player_sidecars';
  StorageFileApi get _files => Supabase.instance.client.storage.from(_bucket);

  String _currentPath(String studentId, String mediaHash) =>
      '$studentId/$mediaHash/current.json';

  String _backupPath(String studentId, String mediaHash, DateTime ts) =>
      '$studentId/$mediaHash/backups/${ts.toIso8601String().replaceAll(':', '-').replaceAll('.', '_')}.json';

  // ====== 로컬 경로 ======
  /// 기본 사이드카 경로 결정 (gtxsc 우선)
  Future<String> resolveLocalPath(String studentDir, {String? initial}) async {
    if (initial != null) return initial;
    final gtx = File(p.join(studentDir, 'current.gtxsc'));
    if (await gtx.exists()) return gtx.path;
    final xsc = File(p.join(studentDir, 'current.xsc'));
    if (await xsc.exists()) return xsc.path;
    return gtx.path; // 기본 경로
  }

  // ====== 원격 I/O ======
  Future<Map<String, dynamic>?> _downloadCurrent(
    String studentId,
    String mediaHash,
  ) async {
    try {
      final bytes = await _files.download(_currentPath(studentId, mediaHash));
      final txt = String.fromCharCodes(bytes);
      final j = jsonDecode(txt);
      return (j is Map<String, dynamic>) ? j.cast<String, dynamic>() : null;
    } on StorageException catch (e) {
      if (e.statusCode == 404) return null; // not found
      rethrow;
    }
  }

  Future<void> _uploadWithBackup({
    required String studentId,
    required String mediaHash,
    required Map<String, dynamic> json,
  }) async {
    final pretty = const JsonEncoder.withIndent('  ').convert(json);
    final bytes = utf8.encode(pretty);
    // current.json 업서트
    await _files.uploadBinary(
      _currentPath(studentId, mediaHash),
      bytes,
      fileOptions: const FileOptions(
        upsert: true,
        contentType: 'application/json',
      ),
    );
    // backups/<iso>.json 추가
    final ts = DateTime.now();
    await _files.uploadBinary(
      _backupPath(studentId, mediaHash, ts),
      bytes,
      fileOptions: const FileOptions(
        upsert: false,
        contentType: 'application/json',
      ),
    );
  }

  // ====== LWW 비교 ======
  DateTime _parseSavedAt(dynamic v) {
    try {
      if (v is String) return DateTime.parse(v);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Map<String, dynamic> _pickLatest(
    Map<String, dynamic>? a,
    Map<String, dynamic>? b,
  ) {
    if (a == null) return b ?? <String, dynamic>{};
    if (b == null) return a;
    final ta = _parseSavedAt(a['savedAt']);
    final tb = _parseSavedAt(b['savedAt']);
    return (tb.isAfter(ta)) ? b : a;
  }

  // ====== 공개 API ======

  /// 로컬/원격 비교 후 최신본을 반환. (없으면 빈 맵)
  Future<Map<String, dynamic>> loadLatest({
    required String studentId,
    required String mediaHash,
    required String studentDir,
    String? initial,
  }) async {
    final localPath = await resolveLocalPath(studentDir, initial: initial);

    Map<String, dynamic>? localJson;
    if (await File(localPath).exists()) {
      try {
        localJson =
            jsonDecode(await File(localPath).readAsString())
                as Map<String, dynamic>;
      } catch (_) {}
    }

    Map<String, dynamic>? remoteJson;
    try {
      remoteJson = await _downloadCurrent(studentId, mediaHash);
    } catch (_) {}

    final latest = _pickLatest(localJson, remoteJson);
    if (latest.isNotEmpty) {
      // 로컬 캐시 갱신
      try {
        await File(localPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert(latest),
          flush: true,
        );
      } catch (_) {}
    }
    return latest;
  }

  /// 사이드카 저장(로컬 + Storage 업로드/백업)
  Future<void> save({
    required String studentId,
    required String mediaHash,
    required String studentDir,
    required Map<String, dynamic> json,
    bool uploadToStorage = true,
  }) async {
    final path = await resolveLocalPath(studentDir);
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
      flush: true,
    );

    if (uploadToStorage) {
      await _uploadWithBackup(
        studentId: studentId,
        mediaHash: mediaHash,
        json: Map<String, dynamic>.from(json),
      );
    }
  }
}
