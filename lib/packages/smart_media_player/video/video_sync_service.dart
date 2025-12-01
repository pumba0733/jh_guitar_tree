// lib/packages/smart_media_player/video/video_sync_service.dart
//
// SmartMediaPlayer v3.8-FF — Step 3 / P2
// Audio = Master / Video = Slave 단방향 VideoSyncService
//
// ✅ 책임
//  - media_kit Player / VideoController 관리 (영상 전용)
//  - EngineApi의 SoT(position, duration, pendingVideoTarget) 기준으로
//    "영상만" seek/재생 상태를 맞춰줌
//  - EngineApi.seekUnified / play / pause 를 절대 호출하지 않음
//
// ✅ 제약
//  - Audio는 100% EngineApi(FFmpeg SoT)가 책임
//  - 이 서비스는 EngineApi에 역으로 영향을 주지 않는다.
//    (seekUnified / play / pause / stopAndUnload 등 호출 금지)

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../engine/engine_api.dart';

void _logVideoSync(String msg, {bool tick = false}) {
  // 기본은 EngineApi 쪽 로그에 묻히지 않게 필요할 때만 켠다고 가정
  const bool kLogTick = false;

  if (tick && !kLogTick) return;

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

  // 마지막으로 강제 align 했던 타임스탬프 (동일 위치 반복 seek 방지용)
  Duration? _lastAlignedTarget;

  // ===============================================================
  // PUBLIC API
  // ===============================================================

  /// SmartMediaPlayerScreen에서 EngineApi.load() 이후
  /// EngineApi가 video 파일로 판단하면 attachPlayer()가 호출됨.
  ///
  /// - Player는 audio=off, keep-open=yes 상태로 열려 있음.
  /// - 여기서는 VideoController 생성 + tick loop 시작만 담당.
  Future<void> attachPlayer(Player player) async {
    if (_disposed) return;

    _player = player;
    _controller ??= VideoController(player);

    _logVideoSync('attachPlayer(): player attached');

    _startTickLoop();
  }

  bool get isVideoLoaded => _player != null && _controller != null;

  VideoController? get controller => _controller;

  /// media_kit Player의 현재 영상 position.
  Duration get videoPosition {
    final p = _player;
    if (p == null) return Duration.zero;
    // media_kit Player.state.position 은 Duration.
    return p.state.position;
  }

  // ===============================================================
  // INTERNAL TICK LOOP
  // ===============================================================

  void _startTickLoop() {
    if (_tickTimer != null) return;
    if (_disposed) return;

    // 대략 80ms 간격 (Audio SoT 50ms 폴링보다 약간 느리게)
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
    _tick().whenComplete(() {
      _tickRunning = false;
    });
  }

  Future<void> _tick() async {
    final engine = EngineApi.instance;

    // 오디오 트랙이 없거나 duration 미정이면 아무 것도 하지 않음
    final dur = engine.duration;
    if (dur <= Duration.zero) {
      return;
    }

    // 영상도 로드된 상태가 아니면 skip
    final player = _player;
    if (player == null) return;

    final audioPos = engine.position;
    final videoPos = player.state.position;

    // 1) pendingVideoTarget 우선 소비 (seekUnified 호출 직후 강제 align)
    Duration? pending = engine.pendingVideoTarget;
    if (pending != null) {
      // EngineApi 쪽 채널은 여기서 소비 후 null로 초기화
      engine.pendingVideoTarget = null;

      // duration 기준 클램프
      if (pending < Duration.zero) pending = Duration.zero;
      if (pending > dur) pending = dur;

      // 동일 타겟으로 반복 seek 방지
      if (_lastAlignedTarget != pending) {
        _lastAlignedTarget = pending;
        await _seekVideo(pending);
        _logVideoSync(
          'tick(): consume pendingVideoTarget=${pending.inMilliseconds}ms',
        );
      } else {
        _logVideoSync(
          'tick(): pendingVideoTarget=${pending.inMilliseconds}ms (same as last), skip',
        );
      }

      return;
    }

    // 2) 일반 SoT 기반 soft sync
    final diffMs = (videoPos - audioPos).inMilliseconds.abs();

    // 너무 작은 차이는 무시
    const softThresholdMs = 60; // 60ms 이내면 그대로 둠
    const hardThresholdMs = 250; // 250ms 이상이면 강제 align

    if (diffMs < softThresholdMs) {
      _logVideoSync(
        'tick(): diff=$diffMs ms (<$softThresholdMs ms), no action',
        tick: true,
      );
      return;
    }

    // hard threshold 이상이면 Audio SoT로 강제 align
    if (diffMs >= hardThresholdMs) {
      // 동일 위치 반복 seek 방지
      final target = audioPos.inMilliseconds < 0
          ? Duration.zero
          : (audioPos > dur ? dur : audioPos);

      if (_lastAlignedTarget == target) {
        _logVideoSync(
          'tick(): diff=$diffMs ms, but target=${target.inMilliseconds}ms already aligned, skip',
        );
        return;
      }

      _lastAlignedTarget = target;
      _logVideoSync(
        'tick(): hard align video to audio, '
        'audio=${audioPos.inMilliseconds}ms, '
        'video=${videoPos.inMilliseconds}ms',
      );
      await _seekVideo(target);
      return;
    }

    // soft 구간(softThreshold ~ hardThreshold)에서는
    // 굳이 seek해서 프레임을 튕기기보다는 자연스러운 차이로 두는 쪽을 채택.
    _logVideoSync(
      'tick(): diff=$diffMs ms (soft zone), keep as is',
      tick: true,
    );
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
    _stopTickLoop();

    // VideoController는 위젯 트리 / 상위 레이어에서 관리되고,
    // 현재 media_kit_video 버전에서는 명시적인 dispose() API가 없다.
    // 여기서는 참조만 끊어준다.
    _controller = null;

    // Player의 생명주기는 EngineApi가 관리하므로 여기서 stop/dispose하지 않음.
    _player = null;

    _logVideoSync('dispose(): service disposed');
  }
}
