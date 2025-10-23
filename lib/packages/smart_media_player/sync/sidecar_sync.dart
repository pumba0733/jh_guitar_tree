// lib/packages/smart_media_player/sync/sidecar_sync.dart
// v2.1.2 | Sidecar sync (Standalone) — throttle + retention + remoteUpdatedAt
// - Bucket: player_sidecars
// - Path:   player_sidecars/<studentId>/<mediaHash>/current.json
// - Backup: player_sidecars/<studentId>/<mediaHash>/backups/<ISO>.json
//
// LWW 우선순위: savedAt → remoteUpdatedAt → positionMs

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

class SidecarSync {
  SidecarSync._();
  static final SidecarSync instance = SidecarSync._();

  // ====== Storage helpers ======
  static const String _bucket = 'player_sidecars';
  StorageFileApi get _files => Supabase.instance.client.storage.from(_bucket);

  String _dirOf(String studentId, String mediaHash) => '$studentId/$mediaHash';
  String _currentPath(String studentId, String mediaHash) =>
      '${_dirOf(studentId, mediaHash)}/current.json';
  String _backupsDir(String studentId, String mediaHash) =>
      '${_dirOf(studentId, mediaHash)}/backups';

  String _backupPath(String studentId, String mediaHash, DateTime ts) =>
      '${_backupsDir(studentId, mediaHash)}/${ts.toIso8601String().replaceAll(':', '-').replaceAll('.', '_')}.json';

  // ====== Throttle / Retention ======
  final Duration _minUploadInterval = const Duration(seconds: 4);
  DateTime? _lastUploadAt;
  DateTime? _dirtySince;

  // retention 정책
  final int _keepLatestN = 5;
  final Duration _keepDays = const Duration(days: 30);
  final Duration _sampleEvery = const Duration(minutes: 10);

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

  // ====== 공용 소형 유틸 ======
  DateTime? _asDateTime(dynamic v) {
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  /// 백업 파일명(예: 2025-10-23T09-12-34_123Z.json)을 DateTime으로 복원
  DateTime? _parseBackupName(String name) {
    final base = p.basenameWithoutExtension(name); // 2025-10-23T09-12-34_123Z
    final parts = base.split('T');
    if (parts.length != 2) return DateTime.tryParse(base);

    final date = parts[0]; // yyyy-mm-dd (그대로 유지)
    var time = parts[1]; // 09-12-34_123Z
    time = time.replaceAll('-', ':'); // 09:12:34_123Z
    time = time.replaceAll('_', '.'); // 09:12:34.123Z
    return DateTime.tryParse('${date}T$time');
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
      // SDK 버전에 따라 statusCode가 int가 아닌 String? 일 수 있음 → 문자열 비교로 통일
      final code = e.statusCode?.toString();
      if (code == '404') return null; // not found
      rethrow;
    }
  }

  Future<List<FileObject>> _list(String dir) async {
    try {
      // Supabase storage SDK: list path is directory prefix
      final res = await _files.list(path: dir);
      return res;
    } on StorageException {
      return <FileObject>[];
    }
  }

  Future<DateTime?> _fetchRemoteUpdatedAt(
    String studentId,
    String mediaHash,
  ) async {
    try {
      final dir = _dirOf(studentId, mediaHash);
      final files = await _list(dir);

      FileObject? cur;
      for (final f in files) {
        if (f.name.toLowerCase() == 'current.json') {
          cur = f;
          break;
        }
      }
      if (cur == null) return null;

      return _asDateTime(cur.updatedAt) ??
          _asDateTime(cur.createdAt) ??
          _asDateTime(cur.lastAccessedAt);
    } catch (_) {
      return null;
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

    // 업로드 후 원격 updated_at을 조회하여 로컬 JSON에 메모
    final remoteTs = await _fetchRemoteUpdatedAt(studentId, mediaHash);
    if (remoteTs != null) {
      json['remoteUpdatedAt'] = remoteTs.toIso8601String();
    }

    _lastUploadAt = DateTime.now();

    // 백업 정리
    await _maybePruneBackups(studentId, mediaHash);
  }

  Future<void> _maybePruneBackups(String studentId, String mediaHash) async {
    try {
      final dir = _backupsDir(studentId, mediaHash);
      final items = await _list(dir);
      if (items.isEmpty) return;

      final now = DateTime.now();
      final entries = <MapEntry<FileObject, DateTime>>[];

      for (final f in items) {
        final t =
            _parseBackupName(f.name) ??
            _asDateTime(f.updatedAt) ??
            _asDateTime(f.createdAt) ??
            _asDateTime(f.lastAccessedAt) ??
            now;
        entries.add(MapEntry(f, t));
      }

      entries.sort((a, b) => b.value.compareTo(a.value)); // desc

      // 1) 최신 N개 보존
      final keep = <String>{};
      for (var i = 0; i < entries.length && i < _keepLatestN; i++) {
        keep.add(entries[i].key.name);
      }

      // 2) 30일 이내는 10분 샘플링 보존
      final sampledSlots = <String, DateTime>{};
      for (final e in entries) {
        if (now.difference(e.value) <= _keepDays) {
          final slot = DateTime(
            e.value.year,
            e.value.month,
            e.value.day,
            e.value.hour,
            (e.value.minute ~/ _sampleEvery.inMinutes) * _sampleEvery.inMinutes,
          );
          final k = slot.toIso8601String().substring(0, 16);
          if (!sampledSlots.containsKey(k)) {
            sampledSlots[k] = e.value;
            keep.add(e.key.name);
          }
        }
      }

      // 3) 나머지 삭제
      for (final e in entries) {
        if (!keep.contains(e.key.name)) {
          await _files.remove(['$dir/${e.key.name}']);
        }
      }
    } catch (_) {
      // 실패해도 무시
    }
  }

  // ====== LWW 비교 ======
  DateTime _parseSavedAt(dynamic v) {
    try {
      if (v is String) return DateTime.parse(v);
    } catch (_) {}
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _parseRemoteAt(dynamic v) {
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
    if (tb.isAfter(ta)) return b;
    if (ta.isAfter(tb)) return a;

    // savedAt 동률/파싱 실패 → remoteUpdatedAt으로 타이브레이크
    final ra = _parseRemoteAt(a['remoteUpdatedAt']);
    final rb = _parseRemoteAt(b['remoteUpdatedAt']);
    if (rb.isAfter(ra)) return b;
    if (ra.isAfter(rb)) return a;

    // 마지막 보조: positionMs 더 최신인 쪽(변경 흔적) 선택
    final pa = (a['positionMs'] as num?)?.toInt() ?? 0;
    final pb = (b['positionMs'] as num?)?.toInt() ?? 0;
    return (pb >= pa) ? b : a;
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
      // 로컬 캐시 갱신(+ 보정: pendingUploadAt 제거)
      final patched = Map<String, dynamic>.from(latest)
        ..remove('pendingUploadAt');
      try {
        await File(localPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert(patched),
          flush: true,
        );
      } catch (_) {}
      return patched;
    }
    return <String, dynamic>{};
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

    // 로컬 즉시 저장(업로드 메타 보정 포함)
    final localJson = Map<String, dynamic>.from(json);
    // 직전 업로드 후에만 pendingUploadAt 제거
    if (_lastUploadAt != null) {
      localJson.remove('pendingUploadAt');
    }
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(localJson),
      flush: true,
    );

    if (!uploadToStorage) return;

    // 업로드 스로틀: 간격 미충족이면 업로드 보류하고 pending 표시
    final now = DateTime.now();
    final since = _lastUploadAt == null
        ? _minUploadInterval
        : now.difference(_lastUploadAt!);

    // 중요 변경 여부(현재는 항상 true → 스로틀 무시하고 업로드)
    bool isImportantChange(Map<String, dynamic> m) {
      // 필요 시 조건 로직으로 교체하세요.
      return true;
    }

    if (since < _minUploadInterval && !isImportantChange(json)) {
      _dirtySince ??= now;
      // 로컬 JSON에 pendingUploadAt 기록
      try {
        final pending = Map<String, dynamic>.from(localJson)
          ..['pendingUploadAt'] = now.toIso8601String();
        await File(path).writeAsString(
          const JsonEncoder.withIndent('  ').convert(pending),
          flush: true,
        );
      } catch (_) {}
      return;
    }

    // 업로드 실행
    await _uploadWithBackup(
      studentId: studentId,
      mediaHash: mediaHash,
      json: localJson,
    );

    _dirtySince = null;

    // 업로드 후 로컬 파일에 remoteUpdatedAt 반영
    try {
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(localJson),
        flush: true,
      );
    } catch (_) {}
  }
}
