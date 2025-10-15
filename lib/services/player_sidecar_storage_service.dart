// lib/services/player_sidecar_storage_service.dart
// v1.0.0 | Player sidecar storage sync (Supabase Storage)
// - Bucket: player_sidecars
// - Path:   player_sidecars/<studentId>/<mediaHash>/current.json
// - Backup: player_sidecars/<studentId>/<mediaHash>/backups/<ISO>.json
//
// NOTE: Storage Realtime은 공식 미지원이므로 LWW로 직접 업/다운로드 관리합니다.

import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlayerSidecarStorageService {
  static final PlayerSidecarStorageService instance =
      PlayerSidecarStorageService._();
  PlayerSidecarStorageService._();

  static const String bucket = 'player_sidecars';

  StorageFileApi get _files => Supabase.instance.client.storage.from(bucket);

  String currentPath(String studentId, String mediaHash) =>
      '$studentId/$mediaHash/current.json';

  String backupPath(String studentId, String mediaHash, DateTime ts) {
    final iso = ts.toIso8601String().replaceAll(':', '-');
    return '$studentId/$mediaHash/backups/$iso.json';
  }

  /// 원격 current.json을 받아 JSON Map으로 반환. 없으면 null
  Future<Map<String, dynamic>?> downloadCurrent(
    String studentId,
    String mediaHash,
  ) async {
    try {
      final bytes = await _files.download(currentPath(studentId, mediaHash));
      final txt = String.fromCharCodes(bytes);
      final j = jsonDecode(txt);
      if (j is Map<String, dynamic>) return j;
      return null;
    } on StorageException catch (e) {
      // 404 등 없는 경우
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// current.json 업로드 + 백업본 저장
  Future<void> uploadWithBackup({
    required String studentId,
    required String mediaHash,
    required Map<String, dynamic> json,
  }) async {
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(json));
    await _files.uploadBinary(
      currentPath(studentId, mediaHash),
      bytes,
      fileOptions: const FileOptions(
        upsert: true,
        contentType: 'application/json',
      ),
    );
    // 백업
    final ts = DateTime.now();
    await _files.uploadBinary(
      backupPath(studentId, mediaHash, ts),
      bytes,
      fileOptions: const FileOptions(
        upsert: false,
        contentType: 'application/json',
      ),
    );
  }

  /// 원격/로컬 중 최신본을 고르기 위한 헬퍼
  static DateTime _parseSavedAt(dynamic v) {
    try {
      if (v is String) return DateTime.parse(v);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// LWW: 원격과 로컬 JSON을 비교하여 더 최신( savedAt )을 반환
  Map<String, dynamic> pickLatest(
    Map<String, dynamic>? a,
    Map<String, dynamic>? b,
  ) {
    if (a == null) return b ?? <String, dynamic>{};
    if (b == null) return a;
    final ta = _parseSavedAt(a['savedAt']);
    final tb = _parseSavedAt(b['savedAt']);
    return (tb.isAfter(ta)) ? b : a;
  }
}
