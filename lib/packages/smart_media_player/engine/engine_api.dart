// lib/packages/smart_media_player/engine/engine_api.dart
//
// SmartMediaPlayer v3.41 — Step 4-1 FINAL ENGINE API
// UI는 EngineApi.instance.xxx() 외에는 절대 엔진 접근 금지.
//
// 책임:
//  - 파일 로드(PCM decode + chain feed)
//  - player/play/pause/seek
//  - tempo/pitch/volume
//  - spaceBehavior
//  - playFromStartCue
//  - unifiedSeek
//  - video sync (80ms tick)
//  - fast-forward / fast-reverse (tick 포함)
//  - position/duration stream 제공
//
import '../../smart_media_player/video/sticky_video_overlay.dart';
import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:flutter/material.dart';

import '../audio/audio_chain_service.dart';
import '../video/video_sync_service.dart';


class EngineApi {
  EngineApi._();
  static final EngineApi instance = EngineApi._();

  // ================================================================
  // CORE FIELDS
  // ================================================================
  Duration _lastStartCue = Duration.zero;
  final Player _player = Player();
  
  final AudioChainService _audio = AudioChainService.instance;

  Duration _duration = Duration.zero;

  // Streams
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration>.broadcast();
  final _playingCtl = StreamController<bool>.broadcast();

  Stream<Duration> get position$ => _positionCtl.stream;
  Stream<Duration> get duration$ => _durationCtl.stream;
  Stream<bool> get playing$ => _playingCtl.stream;

  // ================================================================
  // PUBLIC GETTERS
  // ================================================================
  Player get player => _player; // UI read-only

  Duration get duration => _audio.duration;
  Duration get position =>
      Duration(milliseconds: (_audio.lastPlaybackTime * 1000).round());


  // ================================================================
  // INIT
  // ================================================================
  Future<void> init() async {
    // Step 4-2: chain 초기화는 AudioChainService가 수행함
    MediaKit.ensureInitialized();

    _audio.playbackTime$.listen((tSec) {
      final d = Duration(milliseconds: (tSec * 1000).round());
      _positionCtl.add(d);
      _playingCtl.add(_player.state.playing);
    });


    // === playing stream (media_kit native) ===
    _player.stream.playing.listen((v) {
      _playingCtl.add(v);
    });

        // === END EVENT (재생 종료 시 StartCue로 복귀) — Step 5-2 추가 ===
    // === END EVENT (재생 종료 시 StartCue로 복귀) — Step 5-2 공식 규칙 반영 ===
    // === END EVENT (재생 종료 시 StartCue로 복귀) — Step 5-2 ===
    _player.stream.completed.listen((_) async {
      try {
        // StartCue 가져오기
        Duration cue = _lastStartCue;

        // global clamp
        if (cue < Duration.zero) cue = Duration.zero;
        if (cue > _duration) cue = _duration;

        // 엔진 규칙: 종료 → StartCue로 이동 후 pause
        await seekUnified(cue, startCue: cue);
        await pause();
      } catch (e) {
        debugPrint('[EngineApi] end-event error: $e');
      }
    });
  }


  // ================================================================
  // LOAD MEDIA (PCM decode + chain feed + optional video)
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



    // Step 4-2: decode + feed + duration은 audio_chain_service가 전담
    final (pcm, dur, feed) = await _audio.decodeAndPrepare(path);

    // SoundTouch start
    await _audio.start(feed);

    // Duration 통일
    _duration = dur;
    onDuration(dur);
    _durationCtl.add(dur);
    return _duration;
  }


  // ================================================================
  // PLAYBACK CONTROL
  // ================================================================
  Future<void> play() async => _player.play();
  Future<void> pause() async => _player.pause();
  Future<void> toggle() async => _player.state.playing ? pause() : play();

  // ================================================================
  // SPACE BEHAVIOR
  // ================================================================

  
  Future<void> spaceBehavior(Duration sc) async {
    if (_player.state.playing) {
      await pause();
      return;
    }
    final d = _clamp(sc, Duration.zero, _duration);
    await seekUnified(d);
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
  // TEMPO / PITCH / VOLUME
  // ================================================================
  Future<void> setTempo(double v) async => _audio.setTempo(v.clamp(0.5, 1.5));
  Future<void> setPitch(int semi) async =>
      _audio.setPitch(semi.clamp(-7, 7).toDouble());
  Future<void> setVolume(double v01) async =>
      _audio.setVolume(v01.clamp(0.0, 1.5));

  Future<void> restoreChainState({
    required double tempo,
    required int pitchSemi,
    required double volume,
  }) async {
    await _audio.restoreState(
      tempo: tempo,
      pitchSemi: pitchSemi,
      volume: volume,
    );
  }

  // ================================================================
  // FAST-FORWARD / FAST-REVERSE (STEP 4-4 — seek 기반 완전 통합)
  // ================================================================

  Timer? _ffrwTick;
  bool _ff = false;
  bool _fr = false;
  bool _ffStartedFromPause = false;
  bool _frStartedFromPause = false;

  // Tick 설정
  static const Duration _ffrwInterval = Duration(milliseconds: 55);
  static const Duration _ffStep = Duration(milliseconds: 150);
  static const Duration _frStep = Duration(milliseconds: 150);

  Future<void> _startFfRwTick({
    required bool forward,
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    // 이미 동작 중이면 중복 금지
    _ffrwTick?.cancel();

    // Reverse 시작 시 forward flag false
    // Forward 시작 시 reverse flag false
    _ff = forward;
    _fr = !forward;

    _ffrwTick = Timer.periodic(_ffrwInterval, (_) async {
      // 종료 플래그 체크
      if (!_ff && !_fr) return;

      final cur = position;
      Duration next;

      if (_ff) {
        next = cur + _ffStep;
        if (next > _duration) next = _duration;
      } else {
        next = (cur - _frStep);
        if (next < Duration.zero) next = Duration.zero;
      }

      // Loop/StartCue 정합 보정
      next = _normalizeFfRwPosition(next, startCue, loopA: loopA, loopB: loopB);


      await seekUnified(next);
      await VideoSyncService.instance.align(next);

      // 끝 지점 도달 → 정지
      if (next == Duration.zero && _fr) {
        await fastReverse(false, startCue: startCue);
      }
      if (next == _duration && _ff) {
        await fastForward(false, startCue: startCue);
      }
    });
  }

  // Loop + StartCue 보정 rules
  Duration _normalizeFfRwPosition(
    Duration x,
    Duration startCue, {
    Duration? loopA,
    Duration? loopB,
  }) {
    // global clamp
    if (x < Duration.zero) return Duration.zero;
    if (x > _duration) return _duration;

    // Safety local copies (no underscore)
    final a = loopA;
    Duration? b = loopB;

    // ================================================================
    // LOOP NORMALIZATION (Step 5-2 규칙)
    // ================================================================
    if (a != null && b != null && a < b) {
      // b < a 안전 보정
      if (b < a) {
        b = a + const Duration(milliseconds: 1);
      }

      // Loop 범위 강제
      if (x < a) return a;
      if (x > b) return a;
    }

    // ================================================================
    // START CUE NORMALIZATION
    // ================================================================
    if (x < startCue) {
      return startCue;
    }

    return x;
  }



  // Forward
  Future<void> fastForward(
    bool on, {
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {
    if (on) {
      // 최신 startCue 저장
      _lastStartCue = startCue;

      if (_ff) return;

      final wasPlaying = isPlaying;
      _ffStartedFromPause = !wasPlaying;

      if (!wasPlaying) {
        await seekUnified(startCue);
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

    // off
    if (!_ff) return;
    _ff = false;

    // tick 정리
    _ffrwTick?.cancel();
    _ffrwTick = null;

    // pause 복귀 규칙
    if (_ffStartedFromPause) {
      await pause();
    }

    _ffStartedFromPause = false;
  }

  // Reverse
  Future<void> fastReverse(
    bool on, {
    required Duration startCue,
    Duration? loopA,
    Duration? loopB,
  }) async {

    if (on) {
      // 최신 startCue 저장
      _lastStartCue = startCue;

      if (_fr) return;

      final wasPlaying = isPlaying;
      _frStartedFromPause = !wasPlaying;


      if (!wasPlaying) {
        // STEP 4-4 공식 규칙: reverse 시작 시 StartCue로 먼저 seek
        await seekUnified(startCue);
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

    // off
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
  // CLEANUP
  // ================================================================
  Future<void> dispose() async {
    await VideoSyncService.instance.dispose();
    await _player.dispose();
  }



  // ================================================================
  // UTILS
  // ================================================================
  Duration _clamp(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

    // Step 4-3: VideoSyncService 관리
  bool get hasVideo => VideoSyncService.instance.isVideoLoaded;
  Duration get videoPosition => VideoSyncService.instance.videoPosition;
  VideoController? get videoController => VideoSyncService.instance.controller;


    // ================================================================
  // PUBLIC SAFE GETTERS
  // ================================================================
  bool get isPlaying => _player.state.playing;

    Future<void> playFromStartCue(
    Duration sc, {
    Duration? loopA,
    Duration? loopB,
  }) async {
    // StartCue = LoopA 위로 올라갈 수 없음
    Duration cue = sc;

    if (loopA != null && loopB != null && loopA < loopB) {
      if (cue < loopA) cue = loopA;
      if (cue > loopB) cue = loopA; // loopB 넘어가면 loopA로 리셋
    }

    await spaceBehavior(cue);
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

    Future<void> seekUnified(
    Duration d, {
    Duration? loopA,
    Duration? loopB,
    Duration? startCue,
  }) async {
    // base clamp
    Duration target = _clamp(d, Duration.zero, _duration);

    // Safe local copies — underscore 제거 (lint)
    final a = loopA;
    Duration? b = loopB;

    // ================================================================
    // LOOP NORMALIZATION (Step 5-2 규칙)
    // ================================================================
    if (a != null && b != null && a < b) {
      // b < a 보정 (절대 발생하면 안되지만 안전장치)
      if (b < a) {
        b = a + const Duration(milliseconds: 1);
      }

      // Loop 범위 강제
      if (target < a) target = a;
      if (target > b) target = a;
    }

    // ================================================================
    // START CUE NORMALIZATION (null-safe)
    // ================================================================
        // StartCue normalization (non-null safe)
    if (startCue != null) {
      // base value
      Duration scValue = startCue;

      // clamp startCue to loop range if loop valid
      if (loopA != null && loopB != null && loopA < loopB) {
        if (scValue < loopA) scValue = loopA;
        if (scValue > loopB) scValue = loopA;
      }

      // enforce startCue floor
      if (target < scValue) target = scValue;
    }

    // ================================================================
    // UI SYNC
    // ================================================================
    _positionCtl.add(target);

    // ================================================================
    // SEEK (video → audio 순서)
    // ================================================================
    try {
      await _player.pause();
      await _player.seek(target);
    } catch (_) {}

    // audio chain restart
    await _audio.stop();
    await _audio.startFrom(target);

    // video sync
    await VideoSyncService.instance.align(target);
  }

  // ================================================================
  // PUBLIC FFRW FACADE (UI use)
  // ================================================================
  final FfRwFacade _ffrw = FfRwFacade(EngineApi.instance);
  FfRwFacade get ffrw => _ffrw;

  // ================================================================
  // WAVEFORM BUS / PLAYING STATE
  // ================================================================
  Stream<double> get waveformBus => _audio.playbackTime$;
  bool get playingState => _player.state.playing;

  // === ADD: UI-safe video-loaded flag ===
  bool get isVideoLoaded => VideoSyncService.instance.isVideoLoaded;

  // === ADD: UI-safe video overlay builder ===
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
}


// ================================================================
// PUBLIC FFRW FACADE (UI use)
// ================================================================
// ================================================================
// PUBLIC FFRW FACADE (UI use) — Step 4-4
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