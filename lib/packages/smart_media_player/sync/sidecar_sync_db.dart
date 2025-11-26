// lib/packages/smart_media_player/sync/sidecar_sync_db.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

/// DB(jsonb) + 로컬캐시(LWW) 사이드카 동기화
class SidecarSyncDb {
  SidecarSyncDb._();
  static final SidecarSyncDb instance = SidecarSyncDb._();

  bool _rtBusy = false;
  String? _studentId;
  String? _mediaHash;
  late String _cacheDir;
  StreamSubscription<List<Map<String, dynamic>>>? _rtSub;

  /// 외부에 원격 변경을 알리고 싶으면 등록 (선택)
  void Function(Map<String, dynamic> map)? onRemoteChanged;

  bool get _isBound => _studentId != null && _mediaHash != null;

  Future<void> bind({
    required String studentId,
    required String mediaHash,
    required String localCacheDir,
  }) async {
    _studentId = studentId;
    _mediaHash = mediaHash;
    _cacheDir = p.join(localCacheDir, 'sidecar_local');
    await Directory(_cacheDir).create(recursive: true);

    // 기존 구독 해제 후 재구독
    await _subscribeRealtime();
  }

  Future<void> _subscribeRealtime() async {
    _rtSub?.cancel();
    if (!_isBound) return;

    final supa = Supabase.instance.client;

    _rtSub = supa
        .from('player_sidecars')
        .stream(primaryKey: ['student_id', 'media_hash'])
        .order('updated_at')
        .listen((rows) async {
          if (_rtBusy) return; // 재진입 방지
          if (!_isBound) return;

          _rtBusy = true;
          try {
            // === 1) 대상 row 추출 ===
            final row = rows.firstWhere(
              (r) =>
                  r['student_id'] == _studentId &&
                  r['media_hash'] == _mediaHash,
              orElse: () => {},
            );
            if (row.isEmpty) return;

            // === 2) remote payload / timestamp ===
            final payloadAny = row['payload'];
            final payload = payloadAny is Map
                ? Map<String, dynamic>.from(payloadAny)
                : <String, dynamic>{};

            final remoteTsRaw =
                (payload['savedAt'] ?? payload['saved_at'] ?? '') as String?;
            final remoteTs = DateTime.tryParse(remoteTsRaw ?? '');

            // === 3) local payload / timestamp ===
            final local = await _readLocalOrNull();
            final localTsRaw =
                (local?['savedAt'] ?? local?['saved_at'] ?? '') as String?;
            final localTs = DateTime.tryParse(localTsRaw ?? '');

            // === 4) LWW 판정 ===
            bool acceptRemote = false;
            if (remoteTs == null && localTs == null) {
              acceptRemote = true;
            } else if (remoteTs != null && localTs == null) {
              acceptRemote = true;
            } else if (remoteTs == null && localTs != null) {
              acceptRemote = false;
            } else {
              // 🚩 핵심 LWW: remote >= local → remote 승
              acceptRemote = !remoteTs!.isBefore(localTs!);
            }

            if (acceptRemote) {
              // === 5) atomic write ===
              await _writeLocal(payload);

              final cb = onRemoteChanged;
              if (cb != null) cb(payload);
            }
          } finally {
            _rtBusy = false;
          }
        });
  }


  /// 초기 없으면 생성
  Future<void> upsertInitial({required Map<String, dynamic> initial}) async {
    if (!_isBound) return;
    final supa = Supabase.instance.client;

    final rows = await supa
        .from('player_sidecars')
        .select()
        .eq('student_id', _studentId!)
        .eq('media_hash', _mediaHash!)
        .limit(1);

    if (rows.isEmpty) {
      final nowIso = DateTime.now().toIso8601String();
      final payload = <String, dynamic>{...initial, 'savedAt': nowIso};
      await supa.from('player_sidecars').upsert({
        'student_id': _studentId!,
        'media_hash': _mediaHash!,
        'payload': payload,
        'updated_at': nowIso,
      }, onConflict: 'student_id,media_hash');
      await _writeLocal(payload);
    }
  }

  /// 로드: 로컬 우선 → 없으면 DB
  Future<Map<String, dynamic>> load() async {
    if (!_isBound) return <String, dynamic>{};

    final local = await _readLocalOrNull();
    if (local != null && local.isNotEmpty) return local;

    final supa = Supabase.instance.client;
    final rows = await supa
        .from('player_sidecars')
        .select()
        .eq('student_id', _studentId!)
        .eq('media_hash', _mediaHash!)
        .limit(1);

    if (rows.isNotEmpty) {
      final payloadAny = rows.first['payload'];
      final payload = payloadAny is Map
        ? Map<String, dynamic>.from(payloadAny)
        : <String, dynamic>{};
      await _writeLocal(payload);
      return payload;
    }
    return <String, dynamic>{};
  }

  /// 저장: 로컬 쓰기 → DB upsert (LWW는 서버/구독 측에서 처리)
  Future<void> save(Map<String, dynamic> map, {bool debounce = false}) async {
    if (!_isBound) return;
    // null 값은 jsonb에 굳이 넣지 않도록 제거
    final payload = Map<String, dynamic>.from(map)
      ..removeWhere((k, v) => v == null);

    // 로컬 저장
    await _writeLocal(payload);

    // DB 저장
    final nowIso = DateTime.now().toIso8601String();
    payload['savedAt'] = nowIso;


    // === atomic local write ===
    await _writeLocal(payload);

    // === DB upsert ===
    await Supabase.instance.client.from('player_sidecars').upsert({
      'student_id': _studentId!,
      'media_hash': _mediaHash!,
      'payload': payload,
      'updated_at': nowIso,
    }, onConflict: 'student_id,media_hash');

  }

  Future<Map<String, dynamic>?> _readLocalOrNull() async {
    final fp = await _localFilePath();
    final f = File(fp);
    if (!await f.exists()) return null;
    try {
      final txt = await f.readAsString();
      final j = jsonDecode(txt);
      return j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
    } catch (_) {
      // 🚩 local 파일 손상 → 삭제 처리
      try {
        await f.delete();
      } catch (_) {}
      return null;
    }
  }

  

  Future<void> _writeLocal(Map<String, dynamic> payload) async {
    final fp = await _localFilePath();
    final file = File(fp);
    await file.parent.create(recursive: true);

    final tmp = '$fp.tmp';
    final ftmp = File(tmp);

    await ftmp.writeAsString(jsonEncode(payload), flush: true);
    await ftmp.rename(fp); // atomic swap
  }


  Future<String> _localFilePath() async {
    final name = '${_studentId}_$_mediaHash.json';
    return p.join(_cacheDir, name);
  }

    // ============================================================
  // 3-3C 요구사항: pendingUploadAt + notifier + tryUploadNow()
  // ============================================================

  final ValueNotifier<DateTime?> pendingUploadAtNotifier =
      ValueNotifier<DateTime?>(null);

  DateTime? get pendingUploadAt => pendingUploadAtNotifier.value;

  /// 즉시 업로드 시도. 실패하면 pending 상태 그대로 남김.
  Future<void> tryUploadNow() async {
    if (!_isBound) return;

    final local = await _readLocalOrNull();
    if (local == null || local.isEmpty) return;

    try {
      final nowIso = DateTime.now().toIso8601String();
      await Supabase.instance.client.from('player_sidecars').upsert({
        'student_id': _studentId!,
        'media_hash': _mediaHash!,
        'payload': local,
        'updated_at': nowIso,
      });
      // 성공 → pending 해제
      pendingUploadAtNotifier.value = null;
    } catch (_) {
      // 실패 → pending 유지
      pendingUploadAtNotifier.value ??= DateTime.now();
    }
  }


  void dispose() {
    _rtSub?.cancel();
    _rtSub = null;
  }
}
