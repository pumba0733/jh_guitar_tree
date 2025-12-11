// lib/packages/smart_media_player/video/video_sync_service.dart
//
// SmartMediaPlayer v3.8-FF — Step 4.6 / VideoSyncService tempo-aware soft sync
// Audio = Master / Video = Slave 단방향 VideoSyncService
//
// ✅ 책임
//  - media_kit Player / VideoController 관리 (영상 전용)
//  - EngineApi의 SoT(position, duration, pendingVideoTarget) 기준으로
//    "영상만" position을 맞춤 (오디오는 Master)
//  - EngineApi.seekUnified / play / pause 를 절대 호출하지 않음
//  - ▶ attach 직후: 텍스처 준비(textureReady) 이후 prewarm(play → 짧게 재생 → pause → seek(0))
//    → 첫 진입 검은 화면 제거
//
// ✅ 제약
//  - 오디오는 100% EngineApi(FFmpeg SoT)가 담당
//  - VideoSyncService는 EngineApi에 영향을 주지 않는다
//

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../engine/engine_api.dart';

void _logVideoSync(String msg, {bool tick = false}) {
  const bool kTickLog = false; // tick 로그 보고 싶으면 true
  if (tick && !kTickLog) return;
  debugPrint('[SMP/VideoSync] $msg');
}

class VideoSyncService {
  VideoSyncService._();
  static final VideoSyncService instance = VideoSyncService._();

  Player? _player;
  VideoController? _controller;

  Timer? _tickTimer;
  bool _tickRunning = false;
  bool _disposed = false;

  Duration? _lastAlignedTarget;

  // prewarm 제어
  bool _needsPrewarm = false;
  bool _prewarmedOnce = false;

  // 현재 적용된 비디오 재생 속도(tempo와 동일 스케일)
  double _currentRate = 1.0;
  double get currentRate => _currentRate;

  // tempo ≠ 1.0 구간에서 "큰 사고" 났을 때만 hard align 하기 위한 쿨다운 타임스탬프
  DateTime? _lastHardAlignAt;

  // ===============================================================
  // PUBLIC API
  // ===============================================================

  /// 오디오 tempo 변경 시, 비디오(mp4)에도 동일한 rate를 적용한다.
  ///
  /// - tempo <= 0 이면 1.0으로 대체
  /// - player가 아직 attach되지 않았다면 내부 rate만 저장해두고, attach 시점에 반영
  Future<void> applyTempoToVideo(double tempo) async {
    if (_disposed) return;

    if (tempo <= 0.0) {
      tempo = 1.0;
    }

    _currentRate = tempo;

    final player = _player;
    if (player == null) {
      _logVideoSync(
        'applyTempoToVideo(): store tempo=$_currentRate (player is null)',
      );
      return;
    }

    try {
      await player.setRate(_currentRate);
      _logVideoSync(
        'applyTempoToVideo(): set player rate=${_currentRate.toStringAsFixed(3)}',
      );
    } catch (e) {
      debugPrint('[SMP/VideoSync] applyTempoToVideo error: $e');
    }
  }

  Future<void> attachPlayer(Player player) async {
    if (_disposed) return;

    // 기존 플레이어 정리
    if (_player != null && _player != player) {
      detachPlayer();
    }

    _player = player;
    _controller = VideoController(player);

    // mpv 볼륨 0 (오디오는 네이티브엔진)
    try {
      _player?.setVolume(0.0);
    } catch (_) {}

    // 🔥 현재까지 적용된 tempo(_currentRate)를 새로 붙은 mpv에 바로 반영
    try {
      if (_currentRate <= 0.0) {
        _currentRate = 1.0;
      }
      await _player!.setRate(_currentRate);
      _logVideoSync(
        'attachPlayer(): applied stored rate=${_currentRate.toStringAsFixed(3)}',
      );
    } catch (e) {
      debugPrint('[SMP/VideoSync] attachPlayer setRate error: $e');
    }

    // 상태 초기화
    _lastAlignedTarget = null;
    _needsPrewarm = true;
    _prewarmedOnce = false;
    _lastHardAlignAt = null;

    _logVideoSync(
      'attachPlayer(): player attached, pos=${_player?.state.position.inMilliseconds}ms',
    );

    // -------------------------------------------------------------
    // 🔥 핵심: attach → 텍스처 준비(textureReady) → prewarm
    // -------------------------------------------------------------
    StreamSubscription? _textureSub;
    _textureSub = player.stream.width.listen((w) async {
      final h = player.state.height;
      if (w != null && w > 0 && h != null && h > 0) {
        // texture가 실제로 준비된 시점
        await _triggerPrewarmIfNeeded();

        // 안전하게 두 번째 보정 prewarm (mpv 첫 프레임 안정화)
        await Future.delayed(const Duration(milliseconds: 30));
        await _triggerPrewarmIfNeeded();

        _textureSub?.cancel();
      }
    });

    // tick loop 시작
    _startTickLoop();
  }

  void detachPlayer() {
    if (_player == null && _controller == null && _tickTimer == null) {
      return;
    }

    _stopTickLoop();
    _lastAlignedTarget = null;
    _lastHardAlignAt = null;

    _needsPrewarm = false;
    _prewarmedOnce = false;

    _controller = null;
    _player = null;

    _logVideoSync('detachPlayer(): detached & tick loop stopped');
  }

  bool get isVideoLoaded => _player != null && _controller != null;

  VideoController? get controller => _controller;

  Duration get videoPosition {
    final p = _player;
    if (p == null) return Duration.zero;
    return p.state.position;
  }

  // ===============================================================
  // INTERNAL PREWARM
  // ===============================================================

  Future<void> _triggerPrewarmIfNeeded() async {
    if (_disposed) return;
    if (!_needsPrewarm || _prewarmedOnce) return;

    final player = _player;
    if (player == null) return;

    final engine = EngineApi.instance;
    final dur = engine.duration;

    // duration 불명 → skip
    if (dur <= Duration.zero) {
      _logVideoSync('prewarm: skipped (engine duration <= 0)');
      _needsPrewarm = false;
      _prewarmedOnce = true;
      return;
    }

    // 이미 오디오 재생 중 → prewarm 불필요
    if (engine.isPlaying) {
      _logVideoSync('prewarm: skipped (audio already playing)');
      _needsPrewarm = false;
      _prewarmedOnce = true;
      return;
    }

    _needsPrewarm = false;
    _prewarmedOnce = true;

    _logVideoSync(
      'prewarm: start (play ~150ms → pause → seek(0)) pos=${player.state.position.inMilliseconds}ms',
    );

    try {
      // 1) 첫 프레임 디코딩 유도
      await player.play();
      await Future.delayed(const Duration(milliseconds: 150));
      await player.pause();

      // 2) 0ms로 seek(일관된 초기 상태)
      await player.seek(Duration.zero);

      _logVideoSync('prewarm: done (paused at 0ms)');
    } catch (e) {
      debugPrint('[SMP/VideoSync] prewarm error: $e');
    }
  }

  // ===============================================================
  // TICK LOOP
  // ===============================================================

  void _startTickLoop() {
    if (_tickTimer != null) return;
    if (_disposed) return;

    _tickTimer = Timer.periodic(
      const Duration(milliseconds: 80),
      (_) => _onTick(),
    );

    _logVideoSync('tick loop started');
  }

  void _stopTickLoop() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _logVideoSync('tick loop stopped');
  }

  void _onTick() {
    if (_tickRunning) return;
    if (_disposed) return;
    if (_player == null || _controller == null) return;

    _tickRunning = true;
    _tick().whenComplete(() => _tickRunning = false);
  }

  Future<void> _tick() async {
    final engine = EngineApi.instance;
    final dur = engine.duration;

    if (dur <= Duration.zero) return;

    final player = _player;
    if (player == null) return;

    final audioPos = engine.position;
    final videoState = player.state;
    final videoPos = videoState.position;

    final bool isAudioPlaying = engine.isPlaying;
    final bool isVideoPlaying = videoState.playing;
    final bool isBuffering = videoState.buffering;

    // -----------------------------------------------------------
    // 1) pendingVideoTarget (seekUnified 직후 강제 align)
    //    → 이건 tempo / buffering 여부와 상관없이 "한 번" 확실히 맞춰준다.
    // -----------------------------------------------------------
    Duration? pending = engine.pendingVideoTarget;
    if (pending != null) {
      engine.pendingVideoTarget = null;

      Duration target = pending;
      if (target < Duration.zero) target = Duration.zero;
      if (target > dur) target = dur;

      final alreadyTarget = (_lastAlignedTarget == target);
      final drift = (videoPos - target).inMilliseconds.abs();

      if (alreadyTarget && drift < 40) {
        _logVideoSync(
          'tick(): pendingVideoTarget=${target.inMilliseconds}ms skip (drift=$drift ms)',
        );
      } else {
        _lastAlignedTarget = target;
        _lastHardAlignAt = DateTime.now();
        await _seekVideo(target);
        _logVideoSync(
          'tick(): pendingVideoTarget=${target.inMilliseconds}ms applied (drift=$drift ms)',
        );
      }
      return;
    }

    // -----------------------------------------------------------
    // 2) 일반 SoT 기반 sync
    //    - 오디오 / 비디오가 실제로 "재생 중"이 아니거나
    //      mpv가 buffering이면 건드리지 않는다.
    // -----------------------------------------------------------
    if (!isAudioPlaying || !isVideoPlaying || isBuffering) {
      _logVideoSync(
        'tick(): skip normal sync (audioPlaying=$isAudioPlaying, '
        'videoPlaying=$isVideoPlaying, buffering=$isBuffering)',
        tick: true,
      );
      return;
    }

    // tempo-aware threshold / cooldown 계산
    double tempo = engine.currentTempo;
    if (tempo <= 0.0) tempo = 1.0;
    final double tempoNorm = tempo.clamp(0.5, 2.0);

    // tempo=1.0 기준값 (더 여유롭게)
    const int kBaseSoftMs = 150; // 이 이하면 그냥 놔둔다
    const int kBaseHardMs = 250; // 이 이상이면 한번 맞춰볼 가치 있음
    const Duration kBaseCooldown = Duration(milliseconds: 600);

    // tempo ≠ 1.0 인 구간에서는
    // - 오디오: SoundTouch tempo
    // - 비디오: mpv rate
    // 만 맞춰놓고, 정기적인 seek 기반 sync는 "완전히" 끈다.
    //
    // 이유:
    //  - 느린 템포(0.5~0.8)에서 300~700ms 수준 드리프트는
    //    주기적 seek를 할 만큼 치명적이지 않은 반면,
    //  - 자주 seek하면 mpv가 계속 버퍼링 / 로딩 상태로 들어감.
    if (tempoNorm != 1.0) {
      _logVideoSync(
        'tick(): tempo=${tempo.toStringAsFixed(3)} ≠ 1.0, skip normal sync (rate-only follow)',
        tick: true,
      );
      return;
    }


    final int softThresholdMs = (kBaseSoftMs * (1.0 / tempoNorm))
        .clamp(120.0, 300.0)
        .round();
    final int hardThresholdMs = (kBaseHardMs * (1.0 / tempoNorm))
        .clamp(200.0, 600.0)
        .round();
    final Duration cooldown =
        kBaseCooldown * (1.0 / tempoNorm); // tempo 느릴수록 쿨다운 늘림

    final int signedDiffMs = (videoPos - audioPos).inMilliseconds; // 부호 포함
    final int diffMs = signedDiffMs.abs();

    // 이 정도면 그냥 오차 허용
    if (diffMs < softThresholdMs) {
      _logVideoSync(
        'tick(): diff=$diffMs (<soft=$softThresholdMs, tempo=${tempo.toStringAsFixed(3)}) ignore',
        tick: true,
      );
      return;
    }

    final now = DateTime.now();

    // 너무 자주 맞추지 않기 위한 쿨다운
    if (_lastHardAlignAt != null) {
      final sinceLast = now.difference(_lastHardAlignAt!);

      // soft~hard 사이는 쿨다운 2배, hard 이상이면 기본 쿨다운
      final bool largeDrift = diffMs >= hardThresholdMs;
      final Duration minInterval = largeDrift ? cooldown : cooldown * 2;

      if (sinceLast < minInterval) {
        _logVideoSync(
          'tick(): diff=$diffMs but within cooldown($minInterval), keep '
          '(tempo=${tempo.toStringAsFixed(3)})',
          tick: true,
        );
        return;
      }
    }

    // 실제로 맞춰볼 타깃 = 오디오 위치 (여기서 필요하면 나중에 오프셋 추가 가능)
    Duration rawTarget = audioPos;
    if (rawTarget < Duration.zero) rawTarget = Duration.zero;
    if (rawTarget > dur) rawTarget = dur;

    // 동일 타깃으로 너무 자주 안 건드리기
    final alreadyTarget = (_lastAlignedTarget == rawTarget);
    final drift = (videoPos - rawTarget).inMilliseconds.abs();
    if (alreadyTarget && drift < softThresholdMs) {
      _logVideoSync(
        'tick(): already aligned (drift=$drift ms <soft=$softThresholdMs, '
        'tempo=${tempo.toStringAsFixed(3)})',
        tick: true,
      );
      return;
    }

    _lastAlignedTarget = rawTarget;
    _lastHardAlignAt = now;

    _logVideoSync(
      'tick(): align video → ${rawTarget.inMilliseconds}ms '
      '(audio=${audioPos.inMilliseconds}, video=${videoPos.inMilliseconds}, '
      'diff=$diffMs ms, drift=$drift ms, tempo=${tempo.toStringAsFixed(3)}, '
      'soft=$softThresholdMs, hard=$hardThresholdMs, cooldown=${cooldown.inMilliseconds}ms)',
    );

    await _seekVideo(rawTarget);
  }

  Future<void> _seekVideo(Duration target) async {
    final player = _player;
    if (player == null) return;

    try {
      await player.seek(target);
    } catch (e) {
      debugPrint('[SMP/VideoSync] seekVideo error: $e');
    }
  }

  // ===============================================================
  // LIFECYCLE
  // ===============================================================

  Future<void> dispose() async {
    _disposed = true;

    detachPlayer();
    _logVideoSync('dispose(): service disposed');
  }
}
