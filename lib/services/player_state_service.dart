// lib/services/player_state_service.dart
//
// v1.3.0 | Robust Sidecar State Service
// - Atomic save (tmp -> rename, Win 호환 삭제 후 rename)
// - Debounced autosave + immediate final save on dispose
// - Clamp guard (speed/pitch/volume/repeat) at service-level
// - Loop A/B normalization (A < B 보장; 최소 길이 500ms)
// - Seed listen (새 구독자가 즉시 현재값을 한 번 받도록)
// - Unknown fields (extras) 보존(forward-compat)
// - In-flight save de-dupe & marker 정렬 후 저장
//
// 사용 예:
// final svc = PlayerStateService(sidecarPath: '/path/to/current.gtxsc');
// await svc.load(); // 파일이 있으면 로드
// svc.update(speed: 0.8, notes: '...'); // 내부 디바운스로 저장
// await svc.dispose(); // 마지막 상태 즉시 저장

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum SaveState { idle, saving, saved }

class PlayerMarker {
  Duration t;
  String label;
  String? note;
  int? colorArgb; // ARGB int (e.g., 0xFFRRGGBB)

  PlayerMarker(this.t, this.label, {this.note, this.colorArgb});

  Map<String, dynamic> toJson() => {
    't': t.inMilliseconds,
    'label': label,
    if (note != null) 'note': note,
    if (colorArgb != null) 'color': _argbToHex(colorArgb!),
  };

  static PlayerMarker fromJson(Map<String, dynamic> m) => PlayerMarker(
    Duration(milliseconds: _toInt(m['t'], 0)),
    _toStr(m['label'], ''),
    note: m['note'] as String?,
    colorArgb: _tryParseColor(m['color']),
  );

  static String _argbToHex(int argb) {
    final r = ((argb >> 16) & 0xFF).toRadixString(16).padLeft(2, '0');
    final g = ((argb >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
    final b = (argb & 0xFF).toRadixString(16).padLeft(2, '0');
    return '#${(r + g + b).toUpperCase()}';
  }

  static int? _tryParseColor(dynamic v) {
    if (v == null) return null;
    try {
      String s = v.toString().toUpperCase().replaceAll('#', '');
      if (s.length == 6) s = 'FF$s';
      final n = int.parse(s, radix: 16);
      return n;
    } catch (_) {
      return null;
    }
  }
}

class PlayerStateModel {
  // persisted fields
  final String studentId;
  final String mediaHash;
  final double speed; // 0.5~1.5
  final int pitchSemi; // -7~7
  final Duration? loopA;
  final Duration? loopB;
  final bool loopOn;
  final int loopRepeat; // 0~200 (0 = ∞)
  final Duration position;
  final Duration startCue;
  final List<PlayerMarker> markers;
  final String notes;
  final int volume; // 0~150
  final Map<String, dynamic> extras; // unknowns preserved
  final String version;

  const PlayerStateModel({
    required this.studentId,
    required this.mediaHash,
    required this.speed,
    required this.pitchSemi,
    required this.loopA,
    required this.loopB,
    required this.loopOn,
    required this.loopRepeat,
    required this.position,
    required this.startCue,
    required this.markers,
    required this.notes,
    required this.volume,
    required this.extras,
    required this.version,
  });

  PlayerStateModel copyWith({
    String? studentId,
    String? mediaHash,
    double? speed,
    int? pitchSemi,
    Duration? loopA,
    Duration? loopB,
    bool? loopOn,
    int? loopRepeat,
    Duration? position,
    Duration? startCue,
    List<PlayerMarker>? markers,
    String? notes,
    int? volume,
    Map<String, dynamic>? extras,
    String? version,
  }) {
    return PlayerStateModel(
      studentId: studentId ?? this.studentId,
      mediaHash: mediaHash ?? this.mediaHash,
      speed: speed ?? this.speed,
      pitchSemi: pitchSemi ?? this.pitchSemi,
      loopA: loopA ?? this.loopA,
      loopB: loopB ?? this.loopB,
      loopOn: loopOn ?? this.loopOn,
      loopRepeat: loopRepeat ?? this.loopRepeat,
      position: position ?? this.position,
      startCue: startCue ?? this.startCue,
      markers: markers ?? this.markers,
      notes: notes ?? this.notes,
      volume: volume ?? this.volume,
      extras: extras ?? this.extras,
      version: version ?? this.version,
    );
  }

  Map<String, dynamic> toSidecarJson() {
    final sortedMarkers = [...markers]
      ..sort((a, b) => a.t.compareTo(b.t)); // 저장 전 정렬
    // known fields
    final m = <String, dynamic>{
      'studentId': studentId,
      'mediaHash': mediaHash,
      'speed': speed,
      'pitchSemi': pitchSemi,
      'loopA': loopA?.inMilliseconds ?? 0,
      'loopB': loopB?.inMilliseconds ?? 0,
      'loopOn': loopOn && loopA != null && loopB != null && loopA! < loopB!,
      'loopRepeat': loopRepeat,
      'positionMs': position.inMilliseconds,
      'startCueMs': startCue.inMilliseconds,
      'savedAt': DateTime.now().toIso8601String(),
      'version': version,
      'markers': sortedMarkers.map((e) => e.toJson()).toList(),
      'notes': notes,
      'volume': volume,
    };
    // merge extras (keep unknowns)
    final mm = Map<String, dynamic>.from(extras);
    for (final k in m.keys) {
      mm[k] = m[k];
    }
    return mm;
  }

  static PlayerStateModel fromSidecarJson(Map<String, dynamic> j) {
    final all = Map<String, dynamic>.from(j);
    // extract knowns (and remove from extras)
    T take<T>(String k, T dflt, T Function(dynamic)? cast) {
      final v = all.remove(k);
      if (cast != null) return cast(v);
      return (v is T) ? v : dflt;
    }

    final ver = take<String>('version', 'v3.06.0', (v) => _toStr(v, 'v3.06.0'));
    final loopAms = take<int>('loopA', 0, (v) => _toInt(v, 0));
    final loopBms = take<int>('loopB', 0, (v) => _toInt(v, 0));
    Duration? loopA = loopAms > 0 ? Duration(milliseconds: loopAms) : null;
    Duration? loopB = loopBms > 0 ? Duration(milliseconds: loopBms) : null;
    (loopA, loopB) = _normalizeLoop(loopA, loopB);

    final markersRaw = take<List>('markers', const [], (v) {
      if (v is List) return v;
      return const [];
    });

    final markers =
        markersRaw
            .whereType<Map>()
            .map((e) => PlayerMarker.fromJson(Map<String, dynamic>.from(e)))
            .toList()
          ..sort((a, b) => a.t.compareTo(b.t));

    return PlayerStateModel(
      studentId: take<String>('studentId', '', (v) => _toStr(v, '')),
      mediaHash: take<String>('mediaHash', '', (v) => _toStr(v, '')),
      speed: _clampDouble(
        take('speed', 1.0, (v) => _toDouble(v, 1.0)),
        0.5,
        1.5,
      ),
      pitchSemi: _clampInt(take('pitchSemi', 0, (v) => _toInt(v, 0)), -7, 7),
      loopA: loopA,
      loopB: loopB,
      loopOn:
          take('loopOn', false, (v) => _toBool(v, false)) &&
          loopA != null &&
          loopB != null &&
          loopA! < loopB!,
      loopRepeat: _clampInt(take('loopRepeat', 0, (v) => _toInt(v, 0)), 0, 200),
      position: Duration(
        milliseconds: _clampInt(
          take('positionMs', 0, (v) => _toInt(v, 0)),
          0,
          24 * 60 * 60 * 1000,
        ),
      ),
      startCue: Duration(
        milliseconds: _clampInt(
          take('startCueMs', 0, (v) => _toInt(v, 0)),
          0,
          24 * 60 * 60 * 1000,
        ),
      ),
      markers: markers,
      notes: take<String>('notes', '', (v) => _toStr(v, '')),
      volume: _clampInt(take('volume', 100, (v) => _toInt(v, 100)), 0, 150),
      extras: all, // leftovers
      version: ver,
    );
  }
}

// ===== Service =====
class PlayerStateService {
  PlayerStateService({this.sidecarPath});

  String? sidecarPath;
  final ValueNotifier<SaveState> saveState = ValueNotifier(SaveState.idle);

  final _ctrl = StreamController<PlayerStateModel>.broadcast();
  PlayerStateModel? _cur;
  Timer? _debounce;
  bool _saving = false;
  bool _disposed = false;

  // ---- public API ----
  PlayerStateModel? get current => _cur;

  /// 새 구독자를 위해 현재값을 즉시 한 번 흘려보냅니다(시드).
  Stream<PlayerStateModel> listenWithSeed(void Function(PlayerStateModel) cb) {
    final s = _ctrl.stream.listen(cb);
    final v = _cur;
    if (v != null) scheduleMicrotask(() => cb(v));
    return _ctrl.stream;
  }

  void setSidecarPath(String path) {
    sidecarPath = path;
  }

  Future<void> load({String? path}) async {
    final p = path ?? sidecarPath;
    if (p == null || p.isEmpty) return;
    final f = File(p);
    if (!await f.exists()) return;

    try {
      final txt = await f.readAsString();
      final j = jsonDecode(txt);
      if (j is Map) {
        final model = PlayerStateModel.fromSidecarJson(
          Map<String, dynamic>.from(j),
        );
        _set(model, save: false);
      }
    } catch (_) {
      // ignore malformed sidecar
    }
  }

  /// 모델 업데이트(서비스 레벨 클램프/보정 포함)
  void update({
    String? studentId,
    String? mediaHash,
    double? speed,
    int? pitchSemi,
    Duration? loopA,
    Duration? loopB,
    bool? loopOn,
    int? loopRepeat,
    Duration? position,
    Duration? startCue,
    List<PlayerMarker>? markers,
    String? notes,
    int? volume,
    Map<String, dynamic>? extrasMerge,
    bool save = true,
  }) {
    final cur =
        _cur ??
        PlayerStateModel(
          studentId: studentId ?? '',
          mediaHash: mediaHash ?? '',
          speed: 1.0,
          pitchSemi: 0,
          loopA: null,
          loopB: null,
          loopOn: false,
          loopRepeat: 0,
          position: Duration.zero,
          startCue: Duration.zero,
          markers: const [],
          notes: '',
          volume: 100,
          extras: const {},
          version: 'v3.06.0',
        );

    // clamp
    final sp = speed != null ? _clampDouble(speed, 0.5, 1.5) : null;
    final ps = pitchSemi != null ? _clampInt(pitchSemi, -7, 7) : null;
    final vol = volume != null ? _clampInt(volume, 0, 150) : null;
    final rep = loopRepeat != null ? _clampInt(loopRepeat, 0, 200) : null;

    // loop normalize
    Duration? a = loopA ?? cur.loopA;
    Duration? b = loopB ?? cur.loopB;
    (a, b) = _normalizeLoop(a, b);

    // extras merge
    final extras = Map<String, dynamic>.from(cur.extras);
    if (extrasMerge != null && extrasMerge.isNotEmpty) {
      extras.addAll(extrasMerge);
    }

    final next = cur.copyWith(
      studentId: studentId,
      mediaHash: mediaHash,
      speed: sp,
      pitchSemi: ps,
      loopA: a,
      loopB: b,
      loopOn: loopOn ?? cur.loopOn,
      loopRepeat: rep,
      position: position,
      startCue: startCue,
      markers: markers,
      notes: notes,
      volume: vol,
      extras: extras,
      // version은 유지
    );

    // loopOn은 항상 정합성 재검증
    final validLoopOn =
        next.loopOn &&
        next.loopA != null &&
        next.loopB != null &&
        next.loopA! < next.loopB!;
    final fixed = validLoopOn ? next : next.copyWith(loopOn: false);

    _set(fixed, save: save);
  }

  Future<void> saveNow({String? path}) async {
    final p = path ?? sidecarPath;
    if (p == null || p.isEmpty) return;
    final cur = _cur;
    if (cur == null) return;
    if (_saving) return;
    _saving = true;
    saveState.value = SaveState.saving;
    try {
      final file = File(p);
      await file.parent.create(recursive: true);
      final tmp = File('$p.tmp');

      final jsonStr = const JsonEncoder.withIndent(
        '  ',
      ).convert(cur.toSidecarJson());
      await tmp.writeAsString(jsonStr, flush: true);

      // Windows 호환 rename (덮어쓰기 전 삭제)
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
      await tmp.rename(p);

      saveState.value = SaveState.saved;
      // 잠깐 표시 후 idle
      Future.delayed(const Duration(seconds: 2), () {
        if (!_disposed) saveState.value = SaveState.idle;
      });
    } catch (_) {
      // 실패 시에도 상태는 idle로 복귀
      saveState.value = SaveState.idle;
    } finally {
      _saving = false;
    }
  }

  void saveDebounced({Duration delay = const Duration(milliseconds: 800)}) {
    _debounce?.cancel();
    saveState.value = SaveState.saving;
    _debounce = Timer(delay, () {
      saveNow();
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
    // 마지막 저장 시도
    try {
      await saveNow();
    } catch (_) {}
    await _ctrl.close();
    saveState.dispose();
  }

  // ---- internal ----
  void _set(PlayerStateModel m, {required bool save}) {
    _cur = m;
    if (!_ctrl.isClosed) {
      try {
        _ctrl.add(m);
      } catch (_) {}
    }
    if (save) saveDebounced();
  }
}

// ===== helpers =====
(double? a, double? b) _minMax(double? x, double? y) {
  if (x == null || y == null) return (x, y);
  return x <= y ? (x, y) : (y, x);
}

(Duration?, Duration?) _normalizeLoop(Duration? a, Duration? b) {
  if (a == null || b == null) return (a, b);
  final (aa, bb) = _minMax(
    a.inMilliseconds.toDouble(),
    b.inMilliseconds.toDouble(),
  );
  var A = Duration(milliseconds: aa!.toInt());
  var B = Duration(milliseconds: bb!.toInt());
  if (B <= A) {
    B = A + const Duration(milliseconds: 500);
  }
  return (A, B);
}

String _toStr(dynamic v, String dflt) {
  if (v == null) return dflt;
  return v.toString();
}

int _toInt(dynamic v, int dflt) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? dflt;
  return dflt;
}

double _toDouble(dynamic v, double dflt) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? dflt;
  return dflt;
}

bool _toBool(dynamic v, bool dflt) {
  if (v is bool) return v;
  if (v is String) {
    final s = v.toLowerCase().trim();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return dflt;
}

int _clampInt(int v, int min, int max) => v < min ? min : (v > max ? max : v);
double _clampDouble(double v, double min, double max) =>
    v < min ? min : (v > max ? max : v);
