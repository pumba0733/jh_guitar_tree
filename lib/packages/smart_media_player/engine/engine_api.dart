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

  // ================================================================
  // PUBLIC GETTERS
  // ================================================================
  Player get player => _player; // UI read-only (video 전용)

  Duration get duration => _duration;

  /// FFmpeg SoT 기반 현재 위치
  Duration get position {
    if (!_hasFile) return Duration.zero;
    return stGetPosition();
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

    // FFmpeg SoT polling (position stream)
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_hasFile) return;
      final pos = stGetPosition();
      _positionCtl.add(pos);
    });

    // media_kit playing stream → playing$ (영상 상태와 오디오 상태를 최대한 맞춰준다)
    _player.stream.playing.listen((v) {
      // 오디오는 _nativePlaying 기준이지만, UI 호환성을 위해
      // 비디오 재생 상태도 함께 반영한다.
      final combined = _nativePlaying || v;
      _playingCtl.add(combined);
    });

    // 재생 완료 이벤트 (영상 기준)
    _player.stream.completed.listen((_) async {
      try {
        // StartCue 기준으로 되돌리고 pause
        Duration cue = _lastStartCue;

        // global clamp
        if (cue < Duration.zero) cue = Duration.zero;
        if (cue > _duration) cue = _duration;

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

    return _duration;
  }

  // ================================================================
  // PLAYBACK CONTROL (네이티브 엔진 + 비디오 연동)
  // ================================================================
  Future<void> play() async {
    // 네이티브 엔진에 play 신호 (현재는 stPlay()는 볼륨 기반 헬퍼)
    stPlay();
    _nativePlaying = true;

    try {
      await _player.play();
    } catch (_) {
      // 영상이 없으면 무시
    }

    _playingCtl.add(true);
  }

  Future<void> pause() async {
    // 네이티브 엔진에 pause 신호 (현재는 stPause()가 볼륨=0으로 mute)
    stPause();
    _nativePlaying = false;

    try {
      await _player.pause();
    } catch (_) {
      // 영상이 없으면 무시
    }

    _playingCtl.add(false);
  }

  Future<void> toggle() async {
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
    // 초기 drift 방지만 수행 (StartCue clamp는 screen/WF에서 수행)
    if (position < const Duration(milliseconds: 200) &&
        _duration > Duration.zero &&
        !isPlaying) {
      sc = Duration.zero;
    }

    // 1) 재생 중이면 pause
    if (isPlaying) {
      await pause();
      return;
    }

    // 2) 정지 상태면 StartCue로 seek 후 play
    Duration cue = _clamp(sc, Duration.zero, _duration);

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
    Duration cue = sc;

    if (loopA != null && loopB != null && loopA < loopB) {
      if (cue < loopA) cue = loopA;
      if (cue > loopB) cue = loopA;
    }

    await seekUnified(cue, loopA: loopA, loopB: loopB, startCue: cue);
    await pause();
  }

  // ================================================================
  // TEMPO / PITCH / VOLUME (네이티브 엔진 직접 호출)
  // ================================================================
  Future<void> setTempo(double v) async {
    final clamped = v.clamp(0.5, 1.5);
    st_setTempo(clamped.toDouble());
  }

  Future<void> setPitch(int semi) async {
    final clamped = semi.clamp(-7, 7);
    st_setPitch(clamped.toDouble());
  }

  Future<void> setVolume(double v01) async {
    // 엔진은 0.0~1.0을 기대하지만, UI는 0.0~1.5까지 지원하므로 그대로 전달(엔진 쪽에서 추가 처리 가능)
    final clamped = v01.clamp(0.0, 1.5);
    st_setVolume(clamped.toDouble());
  }

  Future<void> restoreChainState({
    required double tempo,
    required int pitchSemi,
    required double volume,
  }) async {
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
    _ffrwTick?.cancel();

    _ff = forward;
    _fr = !forward;

    _ffrwTick = Timer.periodic(_ffrwInterval, (_) async {
      if (!_ff && !_fr) return;
      if (_seeking) return;

      if (_pendingSeekTarget != null) {
        final t = _pendingSeekTarget!;
        _pendingSeekTarget = null;

        await seekUnified(t, startCue: startCue, loopA: loopA, loopB: loopB);
        return;
      }

      final cur = position;
      Duration next;

      if (_ff) {
        next = cur + _ffStep;
      } else {
        next = cur - _frStep;
      }

      // global clamp
      if (next < Duration.zero) next = Duration.zero;
      if (next > _duration) next = _duration;

      // loop/startCue 보정
      next = _normalizeFfRwPosition(next, startCue, loopA: loopA, loopB: loopB);

      if (_seeking) return;

      if (_pendingSeekTarget != null) {
        final t = _pendingSeekTarget!;
        _pendingSeekTarget = null;
        await seekUnified(t, startCue: startCue, loopA: loopA, loopB: loopB);
        return;
      }

      await seekUnified(next, startCue: startCue, loopA: loopA, loopB: loopB);
      _pendingAlignTarget = next;

      if (next == Duration.zero && _fr) {
        await fastReverse(false, startCue: startCue);
      }
      if (next == _duration && _ff) {
        await fastForward(false, startCue: startCue);
      }
    });
  }

  Duration _normalizeFfRwPosition(
    Duration x,
    Duration startCue, {
    Duration? loopA,
    Duration? loopB,
  }) {
    if (x < Duration.zero) return Duration.zero;
    if (x > _duration) return _duration;

    final a = loopA;
    Duration? b = loopB;

    if (a != null && b != null && a < b) {
      if (b < a) {
        b = a + const Duration(milliseconds: 1);
      }

      if (x < a) return a;
      if (x > b) return a;
    }

    if (x < startCue) return startCue;
    if (a != null && b != null && a < b) {
      if (x > b) return a;
    }

    return x;
  }

  Future<void> fastForward(
    bool on, {
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    if (on) {
      _lastStartCue = startCue;

      if (_ff) return;

      final wasPlaying = isPlaying;
      _ffStartedFromPause = !wasPlaying;

      if (!wasPlaying) {
        await seekUnified(
          startCue,
          startCue: startCue,
          loopA: loopA,
          loopB: loopB,
        );
        _pendingSeekTarget = startCue;
        await play();
      }

      _ff = true;
      _fr = false;

      await _startFfRwTick(
        forward: true,
        startCue: startCue,
        loopA: loopA,
        loopB: loopB,
      );

      return;
    }

    if (!_ff) return;
    _ff = false;

    _ffrwTick?.cancel();
    _ffrwTick = null;

    if (_ffStartedFromPause) {
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
    if (on) {
      _lastStartCue = startCue;

      if (_fr) return;

      final wasPlaying = isPlaying;
      _frStartedFromPause = !wasPlaying;

      if (!wasPlaying) {
        await seekUnified(startCue, startCue: startCue);
        _pendingSeekTarget = startCue;
        await play();
      }

      _fr = true;
      _ff = false;

      await _startFfRwTick(
        forward: false,
        startCue: startCue,
        loopA: loopA,
        loopB: loopB,
      );

      return;
    }

    if (!_fr) return;
    _fr = false;

    _ffrwTick?.cancel();
    _ffrwTick = null;

    if (_frStartedFromPause) {
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
      return;
    }
    _seeking = true;

    final bool wasPlaying = isPlaying;

    Duration target = _clamp(d, Duration.zero, _duration);

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
      Duration sc = startCue;
      if (a != null && b != null && a < b) {
        if (sc < a) sc = a;
        if (sc > b) sc = a;
      }
      if (target < sc) target = sc;
    }

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
      await play();
    } else {
      // 오디오는 정지 상태 유지, 영상도 정지 상태로 맞춰준다.
      try {
        await _player.pause();
      } catch (_) {}
    }
  }

  // ================================================================
  // PUBLIC FACADES
  // ================================================================
  FfRwFacade get ffrw => FfRwFacade(this);

  Future<void> playFromStartCue(
    Duration sc, {
    Duration? loopA,
    Duration? loopB,
  }) async {
    Duration cue = sc;
    if (loopA != null && loopB != null && loopA < loopB) {
      if (cue < loopA) cue = loopA;
      if (cue > loopB) cue = loopA;
    }
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
