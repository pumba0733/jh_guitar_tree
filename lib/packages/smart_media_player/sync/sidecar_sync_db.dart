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
        // ↓ 필터 직접 적용
        .order('updated_at')
        .listen((rows) async {
          final filtered = rows.where(
            (r) =>
                r['student_id'] == _studentId && r['media_hash'] == _mediaHash,
          );
          if (filtered.isEmpty) return;
          final row = filtered.first;

          // payload는 jsonb
          final payloadAny = row['payload'];
          final payload = payloadAny is Map
            ? Map<String, dynamic>.from(payloadAny)
            : <String, dynamic>{};

          // LWW: payload.savedAt 기준으로 로컬/원격 비교 후 최신 반영
          final remoteSavedAt = DateTime.tryParse(
            (payload['savedAt'] ?? payload['saved_at'] ?? '') as String? ?? '',
          );

          final local = await _readLocalOrNull();
          final localSavedAt = DateTime.tryParse(
            (local?['savedAt'] ?? local?['saved_at'] ?? '') as String? ?? '',
          );

          final bool acceptRemote;
          if (remoteSavedAt == null && localSavedAt == null) {
            // 저장시각 정보가 없으면 원격을 우선
            acceptRemote = true;
          } else if (remoteSavedAt != null && localSavedAt == null) {
            acceptRemote = true;
          } else if (remoteSavedAt == null && localSavedAt != null) {
            acceptRemote = false;
          } else {
            acceptRemote = !remoteSavedAt!.isBefore(localSavedAt!);
          }

          if (acceptRemote) {
            await _writeLocal(payload);
            final cb = onRemoteChanged;
            if (cb != null) cb(payload);
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
    final supa = Supabase.instance.client;
    final nowIso = DateTime.now().toIso8601String();
    // savedAt 없으면 주입
    payload['savedAt'] = payload['savedAt'] ?? nowIso;

    await supa.from('player_sidecars').upsert({
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
      return j is Map
          ? Map<String, dynamic>.from(j as Map)
          : <String, dynamic>{};
    } catch (_) {
      return null;
    }
  }

  

  Future<void> _writeLocal(Map<String, dynamic> payload) async {
    final fp = await _localFilePath();
    final f = File(fp);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(payload));
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
