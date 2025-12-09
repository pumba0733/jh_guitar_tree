// lib/packages/smart_media_player/video/video_sync_service.dart
//
// SmartMediaPlayer v3.8-FF — Step 4.5 / VideoSyncService prewarm 즉시실행 버전
// Audio = Master / Video = Slave 단방향 VideoSyncService
//
// ✅ 책임
//  - media_kit Player / VideoController 관리 (영상 전용)
//  - EngineApi의 SoT(position, duration, pendingVideoTarget) 기준으로
//    "영상만" position을 맞춤 (오디오는 Master)
//  - EngineApi.seekUnified / play / pause 를 절대 호출하지 않음
//  - ▶ attach 직후: 렌더 프레임 완료(endOfFrame)를 기다렸다가
//    즉시 prewarm(play → 짧게 재생 → pause → seek(0))
//    → 첫 진입 검은 화면을 제거하는 구조
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

  // ===============================================================
  // PUBLIC API
  // ===============================================================

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

    // 상태 초기화
    _lastAlignedTarget = null;
    _needsPrewarm = true;
    _prewarmedOnce = false;

    _logVideoSync(
      'attachPlayer(): player attached, pos=${_player?.state.position.inMilliseconds}ms',
    );

    // -------------------------------------------------------------
    // 🔥 핵심: attach → 다음 프레임 렌더 완료 시점(endOfFrame) → prewarm
    //
    // Timer 지연 대신 정확한 렌더 타이밍을 잡아서
    // Texture 준비 후 즉시 첫 프레임 디코딩이 가능하도록 함.
    // -------------------------------------------------------------
      // 🔥 NEW: textureReady(width/height > 0) 이벤트를 기다린 뒤 prewarm 실행
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
    final videoPos = player.state.position;

    // -----------------------------------------------------------
    // 1) pendingVideoTarget (seekUnified 직후 강제 align)
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
        await _seekVideo(target);
        _logVideoSync(
          'tick(): pendingVideoTarget=${target.inMilliseconds}ms applied (drift=$drift ms)',
        );
      }
      return;
    }

    // -----------------------------------------------------------
    // 2) 일반 SoT 기반 soft / hard sync
    // -----------------------------------------------------------
    final diffMs = (videoPos - audioPos).inMilliseconds.abs();

    const softThreshold = 60;
    const hardThreshold = 250;

    if (diffMs < softThreshold) {
      _logVideoSync(
        'tick(): diff=$diffMs (<$softThreshold) ignore',
        tick: true,
      );
      return;
    }

    if (diffMs >= hardThreshold) {
      // 강제 align
      Duration rawTarget = audioPos;
      if (rawTarget < Duration.zero) rawTarget = Duration.zero;
      if (rawTarget > dur) rawTarget = dur;

      final alreadyTarget = (_lastAlignedTarget == rawTarget);
      final drift = (videoPos - rawTarget).inMilliseconds.abs();

      if (alreadyTarget && drift < 40) {
        _logVideoSync(
          'tick(): hard align skip (already aligned, drift=$drift ms)',
        );
        return;
      }

      _lastAlignedTarget = rawTarget;

      _logVideoSync(
        'tick(): hard align video → ${rawTarget.inMilliseconds}ms '
        '(audio=${audioPos.inMilliseconds}, video=${videoPos.inMilliseconds}, drift=$drift ms)',
      );
      await _seekVideo(rawTarget);
      return;
    }

    // soft zone
    _logVideoSync('tick(): diff=$diffMs soft zone, keep', tick: true);
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
