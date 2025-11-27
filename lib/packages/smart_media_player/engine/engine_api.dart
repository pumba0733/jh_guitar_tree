// lib/packages/smart_media_player/engine/engine_api.dart
//
// SmartMediaPlayer v3.8-FF — STEP 4
// EngineApi = FFmpeg 네이티브 엔진 thin wrapper + mpv(video-only)
//
// 책임:
//  - 파일 로드(FFmpeg 네이티브 엔진 openFile)
//  - player/play/pause/seekUnified
//  - tempo/pitch/volume (네이티브 엔진)
//  - spaceBehavior / playFromStartCue
//  - unified seek (audio master, video slave)
//  - video sync 보조 (VideoSyncService에 pending target 제공)
//  - position/duration stream (FFmpeg SoT 기반)
//  - FFRW (seek 기반 시뮬레이션)
//
// 제약:
//  - 오디오는 100% 네이티브 엔진이 담당 (FFmpeg + SoundTouch + miniaudio)
//  - media_kit Player는 영상 렌더링 및 완료 이벤트 전용
//

import '../../smart_media_player/video/sticky_video_overlay.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../audio/engine_soundtouch_ffi.dart';
import '../video/video_sync_service.dart';

// ================================================================
// SoT / Playback QA 로깅 헬퍼
// ================================================================

// ✅ 기본 이벤트(로드/플레이/일시정지/시크 등) 로그
const bool kSmpEngineLogBasic = true;

// ✅ SoT tick / FFRW tick 같이 "자주 찍히는 로그" 전용 스위치
//   → 평소에는 false로 두고, QA 땐 true로 올려서 쓰면 됨.
const bool kSmpEngineLogTick = false;

void _logSmpEngine(String message, {bool tick = false}) {
  if (tick) {
    if (!kSmpEngineLogTick) return;
  } else {
    if (!kSmpEngineLogBasic) return;
  }
  debugPrint('[SMP/EngineApi] $message');
}

class EngineApi {
  EngineApi._();
  static final EngineApi instance = EngineApi._();

  // ================================================================
  // CORE FIELDS
  // ================================================================
  final Player _player = Player(); // video 전용
  bool _initialized = false;
  bool _hasFile = false;

  Duration _duration = Duration.zero;
  Duration _lastStartCue = Duration.zero;

  // 네이티브 엔진 재생 상태(오디오 기준)
  bool _nativePlaying = false;

  // SEEK LOCKING SYSTEM (Phase D 개념 유지, 구현은 FFmpeg 기반으로 변경)
  bool _seeking = false; // seekUnified() 실행 중 보호 플래그
  Duration? _pendingSeekTarget; // VideoSyncService에서 소비할 pending target
  Duration? _pendingAlignTarget; // VideoSyncService align 요청용

  // Streams
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration>.broadcast();
  final _playingCtl = StreamController<bool>.broadcast();

  Stream<Duration> get position$ => _positionCtl.stream;
  Stream<Duration> get duration$ => _durationCtl.stream;
  Stream<bool> get playing$ => _playingCtl.stream;

  // FFmpeg SoT polling용 타이머
  Timer? _positionTimer;
  DateTime? _lastPosLogAt;

  // ================================================================
  // PUBLIC GETTERS
  // ================================================================
  Player get player => _player; // UI read-only (video 전용)

  Duration get duration => _duration;

  /// FFmpeg SoT 기반 현재 위치 (항상 [0, duration] 범위로 클램프)
  Duration get position {
    if (!_hasFile || _duration <= Duration.zero) return Duration.zero;
    final raw = stGetPosition();
    final pos = _clampToDuration(raw);
    return pos;
  }

  bool get isPlaying => _nativePlaying;

  // VideoSyncService bridge
  bool get hasVideo => VideoSyncService.instance.isVideoLoaded;
  Duration get videoPosition => VideoSyncService.instance.videoPosition;
  VideoController? get videoController => VideoSyncService.instance.controller;

  // VideoSyncService Phase E 채널
  Duration? get pendingSeekTarget => _pendingSeekTarget;
  set pendingSeekTarget(Duration? v) => _pendingSeekTarget = v;

  Duration? get pendingAlignTarget => _pendingAlignTarget;
  set pendingAlignTarget(Duration? v) => _pendingAlignTarget = v;

  // ================================================================
  // INIT
  // ================================================================
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    MediaKit.ensureInitialized();
    stInitEngine();
    _logSmpEngine('init(): engine initialized');

    // FFmpeg SoT polling (position stream)
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_hasFile) return;

      final raw = stGetPosition();
      final pos = (_duration > Duration.zero)
          ? _clampToDuration(raw)
          : raw; // duration 미정일 때는 raw 그대로

      _positionCtl.add(pos);

      // SoT 로깅 (500ms 이상 간격으로만 + tick 채널에만)
      final now = DateTime.now();
      if (_lastPosLogAt == null ||
          now.difference(_lastPosLogAt!) >= const Duration(milliseconds: 500)) {
        _lastPosLogAt = now;
        _logSmpEngine(
          'tick: pos=${pos.inMilliseconds}ms, dur=${_duration.inMilliseconds}ms, playing=$_nativePlaying',
          tick: true,
        );
      }
    });

    // media_kit playing stream → playing$ (영상 상태와 오디오 상태를 최대한 맞춰준다)
    _player.stream.playing.listen((v) {
      // 오디오는 _nativePlaying 기준이지만, UI 호환성을 위해
      // 비디오 재생 상태도 함께 반영한다.
      final combined = _nativePlaying || v;
      _playingCtl.add(combined);
      _logSmpEngine('player.stream.playing: mpvPlaying=$v, combined=$combined');
    });

    // 재생 완료 이벤트 (영상 기준)
    _player.stream.completed.listen((_) async {
      try {
        // StartCue는 항상 duration 범위로 클램프된 값 사용
        final cue = _clampToDuration(_lastStartCue);

        _logSmpEngine(
          'completed: seek back to StartCue=${cue.inMilliseconds}ms',
        );

        await seekUnified(cue, startCue: cue);
        await pause();
      } catch (e) {
        debugPrint('[EngineApi] end-event error: $e');
      }
    });
  }

  // ================================================================
  // LOAD MEDIA (FFmpeg 네이티브 엔진 + optional video)
  // ================================================================
  Future<Duration> load({
    required String path,
    required void Function(Duration) onDuration,
  }) async {
    await init();

    final f = File(path);
    if (!await f.exists()) {
      throw Exception('[EngineApi] File not found: $path');
    }

    _logSmpEngine('load(): path=$path');

    // 이전 파일 정리
    stCloseFile();
    _hasFile = false;
    _duration = Duration.zero;
    _lastStartCue = Duration.zero;
    _pendingSeekTarget = null;
    _pendingAlignTarget = null;
    _nativePlaying = false;
    _playingCtl.add(false);

    // 네이티브 엔진에 파일 오픈
    final ok = stOpenFile(path);
    if (!ok) {
      throw Exception(
        '[EngineApi] Failed to open file via native engine: $path',
      );
    }
    _hasFile = true;

    // FFmpeg duration 확보
    _duration = stGetDuration();
    if (_duration < Duration.zero) {
      _duration = Duration.zero;
    }
    _lastStartCue = Duration.zero;

    onDuration(_duration);
    _durationCtl.add(_duration);

    // === Video path (audio disabled, keep-open) ===
    final lower = path.toLowerCase();
    final isVideo =
        lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv');

    if (isVideo) {
      await _player.open(
        Media(path, extras: {'audio': 'no', 'keep-open': 'yes'}),
        play: false,
      );
      await VideoSyncService.instance.attachPlayer(_player);
    }

    // 오디오/비디오 모두 0으로 강제 align
    stSeekToDuration(Duration.zero);
    if (isVideo) {
      try {
        await _player.seek(Duration.zero);
        await VideoSyncService.instance.align(Duration.zero);
      } catch (e) {
        debugPrint('[EngineApi] load() initial align error: $e');
      }
    }

    _positionCtl.add(Duration.zero);

    _logSmpEngine(
      'load(): duration=${_duration.inMilliseconds}ms, isVideo=$isVideo',
    );

    return _duration;
  }

  // ================================================================
  // PLAYBACK CONTROL (네이티브 엔진 + 비디오 연동)
  // ================================================================
  Future<void> play() async {
    final cur = position;
    _logSmpEngine(
      'play() requested at pos=${cur.inMilliseconds}ms, nativePlaying=$_nativePlaying',
    );

    // 네이티브 엔진에 play 신호
    stPlay();
    _nativePlaying = true;

    try {
      await _player.play();
    } catch (_) {
      // 영상이 없으면 무시
    }

    _playingCtl.add(true);
    _logSmpEngine('play(): now nativePlaying=$_nativePlaying');
  }

  Future<void> pause() async {
    final cur = position;
    _logSmpEngine(
      'pause() requested at pos=${cur.inMilliseconds}ms, nativePlaying=$_nativePlaying',
    );

    // 네이티브 엔진에 pause 신호
    stPause();
    _nativePlaying = false;

    try {
      await _player.pause();
    } catch (_) {
      // 영상이 없으면 무시
    }

    _playingCtl.add(false);
    _logSmpEngine('pause(): now nativePlaying=$_nativePlaying');
  }

  Future<void> toggle() async {
    _logSmpEngine('toggle(): isPlaying=$isPlaying');
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  // ================================================================
  // SPACE BEHAVIOR
  // ================================================================
  Future<void> spaceBehavior(Duration sc) async {
    final cur = position;
    final durMs = _duration.inMilliseconds;
    _logSmpEngine(
      'spaceBehavior() called with sc=${sc.inMilliseconds}ms, cur=${cur.inMilliseconds}ms, dur=$durMs, isPlaying=$isPlaying',
    );

    // 0 근처 + 정지 상태이면 StartCue를 0으로 정규화
    if (cur < const Duration(milliseconds: 200) &&
        _duration > Duration.zero &&
        !isPlaying) {
      sc = Duration.zero;
      _logSmpEngine(
        'spaceBehavior(): normalize sc to 0 due to near-start & not playing',
      );
    }

    // 1) 재생 중이면 pause
    if (isPlaying) {
      _logSmpEngine('spaceBehavior(): currently playing → pause()');
      await pause();
      return;
    }

    // 2) 정지 상태면 StartCue로 seek 후 play
    Duration cue = _clampToDuration(sc);
    _lastStartCue = cue;

    _logSmpEngine(
      'spaceBehavior(): seek to cue=${cue.inMilliseconds}ms then play()',
    );

    await seekUnified(cue, startCue: cue);
    _pendingSeekTarget = cue; // VideoSyncService와의 통합 경로
    await play();
  }

  // ================================================================
  // LOOP EXIT → StartCue + Pause
  // ================================================================
  Future<void> loopExitToStartCue(
    Duration sc, {
    Duration? loopA,
    Duration? loopB,
  }) async {
    _logSmpEngine(
      'loopExitToStartCue(): sc=${sc.inMilliseconds}ms, loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
    );

    Duration cue = _clampToDuration(sc);

    if (loopA != null && loopB != null && loopA < loopB) {
      if (cue < loopA) cue = loopA;
      if (cue > loopB) cue = loopA;
    }

    cue = _clampToDuration(cue);
    _lastStartCue = cue;

    _logSmpEngine(
      'loopExitToStartCue(): normalized cue=${cue.inMilliseconds}ms',
    );

    await seekUnified(cue, loopA: loopA, loopB: loopB, startCue: cue);
    await pause();
  }

  // ================================================================
  // TEMPO / PITCH / VOLUME (네이티브 엔진 직접 호출)
  // ================================================================
  Future<void> setTempo(double v) async {
    final clamped = v.clamp(0.5, 1.5);
    _logSmpEngine('setTempo(): v=$v → clamped=$clamped');
    st_setTempo(clamped.toDouble());
  }

  Future<void> setPitch(int semi) async {
    final clamped = semi.clamp(-7, 7);
    _logSmpEngine('setPitch(): semi=$semi → clamped=$clamped');
    st_setPitch(clamped.toDouble());
  }

  Future<void> setVolume(double v01) async {
    final clamped = v01.clamp(0.0, 1.5);
    _logSmpEngine('setVolume(): v01=$v01 → clamped=$clamped');
    st_setVolume(clamped.toDouble());
  }

  Future<void> restoreChainState({
    required double tempo,
    required int pitchSemi,
    required double volume,
  }) async {
    _logSmpEngine(
      'restoreChainState(): tempo=$tempo, pitchSemi=$pitchSemi, volume=$volume',
    );
    await setTempo(tempo);
    await setPitch(pitchSemi);
    await setVolume(volume);
  }

  Future<void> tempo(double v) async => setTempo(v);
  Future<void> pitch(int semi) async => setPitch(semi);
  Future<void> volume(double v01) async => setVolume(v01);

  Future<void> restoreState({
    required double tempo,
    required int pitchSemi,
    required double volume,
  }) async {
    await restoreChainState(tempo: tempo, pitchSemi: pitchSemi, volume: volume);
  }

  // ================================================================
  // FAST-FORWARD / FAST-REVERSE (seek 기반 시뮬레이션)
  // ================================================================
  Timer? _ffrwTick;
  bool _ff = false;
  bool _fr = false;
  bool _ffStartedFromPause = false;
  bool _frStartedFromPause = false;

  static const Duration _ffrwInterval = Duration(milliseconds: 55);
  static const Duration _ffStep = Duration(milliseconds: 150);
  static const Duration _frStep = Duration(milliseconds: 150);

  Future<void> _startFfRwTick({
    required bool forward,
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    final scNorm = _clampToDuration(startCue);

    _logSmpEngine(
      '_startFfRwTick(): forward=$forward, startCue=${scNorm.inMilliseconds}ms, loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
    );

    _ffrwTick?.cancel();

    _ff = forward;
    _fr = !forward;

    _ffrwTick = Timer.periodic(_ffrwInterval, (_) async {
      if (!_ff && !_fr) return;
      if (_seeking) return;

      if (_pendingSeekTarget != null) {
        final t = _clampToDuration(_pendingSeekTarget!);
        _pendingSeekTarget = null;

        _logSmpEngine(
          'FFRW tick: consume pendingSeekTarget=${t.inMilliseconds}ms',
          tick: true,
        );

        await seekUnified(t, startCue: scNorm, loopA: loopA, loopB: loopB);
        return;
      }

      final cur = position;
      Duration next;

      if (_ff) {
        next = cur + _ffStep;
      } else {
        next = cur - _frStep;
      }

      next = _normalizeFfRwPosition(next, scNorm, loopA: loopA, loopB: loopB);

      if (_seeking) return;

      if (_pendingSeekTarget != null) {
        final t = _clampToDuration(_pendingSeekTarget!);
        _pendingSeekTarget = null;
        _logSmpEngine(
          'FFRW tick: override by pendingSeekTarget=${t.inMilliseconds}ms',
          tick: true,
        );
        await seekUnified(t, startCue: scNorm, loopA: loopA, loopB: loopB);
        return;
      }

      await seekUnified(next, startCue: scNorm, loopA: loopA, loopB: loopB);
      _pendingAlignTarget = next;

      if (next == Duration.zero && _fr) {
        _logSmpEngine('FFRW tick: reached 0ms in FR → stop', tick: true);
        await fastReverse(false, startCue: scNorm);
      }
      if (next == _duration && _ff) {
        _logSmpEngine(
          'FFRW tick: reached end(${_duration.inMilliseconds}ms) in FF → stop',
          tick: true,
        );
        await fastForward(false, startCue: scNorm);
      }
    });
  }

  Duration _normalizeFfRwPosition(
    Duration x,
    Duration startCue, {
    Duration? loopA,
    Duration? loopB,
  }) {
    // 전체 duration 기준 1차 클램프
    Duration v = _clampToDuration(x);

    final a = loopA;
    Duration? b = loopB;

    if (a != null && b != null && a < b) {
      if (b < a) {
        b = a + const Duration(milliseconds: 1);
      }

      if (v < a) return a;
      if (v > b) return a;
    }

    if (v < startCue) return startCue;
    if (a != null && b != null && a < b) {
      if (v > b) return a;
    }

    return _clampToDuration(v);
  }

  Future<void> fastForward(
    bool on, {
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    final scNorm = _clampToDuration(startCue);

    if (on) {
      _logSmpEngine(
        'fastForward(on): startCue=${scNorm.inMilliseconds}ms, loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
      );

      _lastStartCue = scNorm;

      if (_ff) return;

      final wasPlaying = isPlaying;
      _ffStartedFromPause = !wasPlaying;

      if (!wasPlaying) {
        _logSmpEngine('fastForward(on): wasPaused → seek to StartCue & play');
        await seekUnified(scNorm, startCue: scNorm, loopA: loopA, loopB: loopB);
        _pendingSeekTarget = scNorm;
        await play();
      }

      _ff = true;
      _fr = false;

      await _startFfRwTick(
        forward: true,
        startCue: scNorm,
        loopA: loopA,
        loopB: loopB,
      );

      return;
    }

    if (!_ff) return;
    _ff = false;

    _logSmpEngine('fastForward(off): stop FFRW');

    _ffrwTick?.cancel();
    _ffrwTick = null;

    if (_ffStartedFromPause) {
      _logSmpEngine('fastForward(off): returning to pause()');
      await pause();
    }

    _ffStartedFromPause = false;
  }

  Future<void> fastReverse(
    bool on, {
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    final scNorm = _clampToDuration(startCue);

    if (on) {
      _logSmpEngine(
        'fastReverse(on): startCue=${scNorm.inMilliseconds}ms, loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
      );

      _lastStartCue = scNorm;

      if (_fr) return;

      final wasPlaying = isPlaying;
      _frStartedFromPause = !wasPlaying;

      if (!wasPlaying) {
        _logSmpEngine('fastReverse(on): wasPaused → seek to StartCue & play');
        await seekUnified(scNorm, startCue: scNorm);
        _pendingSeekTarget = scNorm;
        await play();
      }

      _fr = true;
      _ff = false;

      await _startFfRwTick(
        forward: false,
        startCue: scNorm,
        loopA: loopA,
        loopB: loopB,
      );

      return;
    }

    if (!_fr) return;
    _fr = false;

    _logSmpEngine('fastReverse(off): stop FFRW');

    _ffrwTick?.cancel();
    _ffrwTick = null;

    if (_frStartedFromPause) {
      _logSmpEngine('fastReverse(off): returning to pause()');
      await pause();
    }

    _frStartedFromPause = false;
  }

  // ================================================================
  // UNIFIED SEEK (FFmpeg 네이티브 엔진 기준)
  // ================================================================
  Future<void> seekUnified(
    Duration d, {
    Duration? loopA,
    Duration? loopB,
    Duration? startCue,
  }) async {
    if (_seeking) {
      _logSmpEngine(
        'seekUnified(): already seeking, ignore new request d=${d.inMilliseconds}ms',
      );
      return;
    }

    if (_duration <= Duration.zero) {
      _logSmpEngine(
        'seekUnified(): duration is zero, ignore seek d=${d.inMilliseconds}ms',
      );
      return;
    }

    _seeking = true;

    final bool wasPlaying = isPlaying;

    Duration target = _clampToDuration(d);
    final originalTargetMs = target.inMilliseconds;

    // loop normalization
    final a = loopA;
    Duration? b = loopB;
    if (a != null && b != null && a < b) {
      if (b < a) b = a + const Duration(milliseconds: 1);
      if (target < a) target = a;
      if (target > b) target = a;
    }

    // start cue normalization
    if (startCue != null) {
      Duration sc = _clampToDuration(startCue);
      if (a != null && b != null && a < b) {
        if (sc < a) sc = a;
        if (sc > b) sc = a;
      }
      if (target < sc) target = sc;
      _lastStartCue = sc;
    }

    target = _clampToDuration(target);

    _logSmpEngine(
      'seekUnified(): d=${d.inMilliseconds}ms, origTarget=$originalTargetMs ms, loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}, startCue=${startCue?.inMilliseconds} → finalTarget=${target.inMilliseconds}ms, wasPlaying=$wasPlaying',
    );

    _positionCtl.add(target);

    try {
      // 1) FFmpeg 네이티브 엔진 seek
      stSeekToDuration(target);

      // 2) VideoSyncService에 알리기 위한 pending target 설정
      _pendingSeekTarget = target;
      _pendingAlignTarget = target;

      // 3) mpv에도 동일 위치로 seek (영상 존재 시)
      try {
        await _player.seek(target);
      } catch (e) {
        debugPrint('[EngineApi] player.seek error: $e');
      }
    } catch (e) {
      debugPrint('[EngineApi] seekUnified error: $e');
    } finally {
      _seeking = false;
    }

    if (wasPlaying) {
      _logSmpEngine('seekUnified(): resume play after seek');
      await play();
    } else {
      // 오디오는 정지 상태 유지, 영상도 정지 상태로 맞춰준다.
      try {
        await _player.pause();
      } catch (_) {}
      _logSmpEngine('seekUnified(): keep paused after seek');
    }
  }

  // ================================================================
  // PUBLIC FFRW FACADE & HELPERS
  // ================================================================
  FfRwFacade get ffrw => FfRwFacade(this);

  Future<void> playFromStartCue(
    Duration sc, {
    Duration? loopA,
    Duration? loopB,
  }) async {
    Duration cue = _clampToDuration(sc);
    _logSmpEngine(
      'playFromStartCue(): sc=${sc.inMilliseconds}ms (norm=${cue.inMilliseconds}ms), loopA=${loopA?.inMilliseconds}, loopB=${loopB?.inMilliseconds}',
    );

    if (loopA != null && loopB != null && loopA < loopB) {
      if (cue < loopA) cue = loopA;
      if (cue > loopB) cue = loopA;
    }

    cue = _clampToDuration(cue);
    _lastStartCue = cue;

    await spaceBehavior(cue);
  }

  // StickyVideoOverlay helper (Step 7까지 임시 유지)
  Widget buildVideoOverlay({
    required ScrollController scrollController,
    required Size viewportSize,
    double collapseScrollPx = 480.0,
    double miniWidth = 360.0,
  }) {
    final vc = VideoSyncService.instance.controller;
    if (vc == null) return const SizedBox.shrink();

    return StickyVideoOverlay(
      controller: vc,
      scrollController: scrollController,
      viewportSize: viewportSize,
      collapseScrollPx: collapseScrollPx,
      miniWidth: miniWidth,
    );
  }

  // ================================================================
  // CLEANUP
  // ================================================================
  Future<void> dispose() async {
    _logSmpEngine('dispose(): cleaning up engine & player');

    try {
      _ffrwTick?.cancel();
      _ffrwTick = null;
      _positionTimer?.cancel();
      _positionTimer = null;

      await VideoSyncService.instance.dispose();
      await _player.dispose();
    } catch (_) {}

    stCloseFile();
    stDisposeEngine();

    _hasFile = false;
    _nativePlaying = false;

    await _positionCtl.close();
    await _durationCtl.close();
    await _playingCtl.close();
  }

  // ================================================================
  // UTILS
  // ================================================================
  Duration _clamp(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  /// duration(SoT 축) 기준 글로벌 클램프
  Duration _clampToDuration(Duration v) {
    if (_duration <= Duration.zero) return Duration.zero;
    return _clamp(v, Duration.zero, _duration);
  }
}

// ================================================================
// PUBLIC FFRW FACADE (UI use)
// ================================================================
class FfRwFacade {
  final EngineApi api;
  FfRwFacade(this.api);

  Future<void> startForward({
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
    required bool loopOn,
  }) {
    return api.fastForward(
      true,
      startCue: startCue,
      loopA: loopOn ? loopA : null,
      loopB: loopOn ? loopB : null,
    );
  }

  Future<void> stopForward() =>
      api.fastForward(false, startCue: api._lastStartCue);

  Future<void> startReverse({
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
    required bool loopOn,
  }) {
    return api.fastReverse(
      true,
      startCue: startCue,
      loopA: loopOn ? loopA : null,
      loopB: loopOn ? loopB : null,
    );
  }

  Future<void> stopReverse() =>
      api.fastReverse(false, startCue: api._lastStartCue);
}
