// lib/packages/smart_media_player/video/video_sync_service.dart
//
// SmartMediaPlayer v3.8-FF — STEP 5 VideoSyncService (FFmpeg SoT 기반 최종본)
//
// 책임:
//  - VideoController 생성 및 보관
//  - mpv(Player)와 EngineApi(FFmpeg 오디오 SoT) 사이 A/V 싱크 유지
//  - pendingSeekTarget / pendingAlignTarget 소비
//  - 50ms 주기 드리프트 체크 + ±100ms 기준 보정
//
// A/V 싱크 원칙 (Hybrid APlan v3.8-FF):
//  - 오디오 = 마스터 (FFmpeg + SoundTouch + miniaudio 타임라인)
//  - 비디오 = 슬레이브 (mpv; 오차가 커질 때만 오디오 시각에 맞춰 seek)
//  - 목표 오차 범위: ±50ms 이내 유지
//  - 실제 보정 트리거: |video - audio| > 100ms 일 때만 강제 align
//
// 참고:
//  - EngineApi.position  → FFmpeg 오디오 SoT(Duration)
//  - EngineApi.pendingSeekTarget / pendingAlignTarget
//      → EngineApi에서 발생한 unified seek / 강제 align 요청을
//        VideoSyncService가 소비하여 mpv에 반영하기 위한 훅

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../engine/engine_api.dart';

// ============================================================
// SoT / Video Sync QA 로깅 헬퍼
// ============================================================

// ✅ attach/align 같은 큰 이벤트
const bool kSmpVideoSyncLogBasic = true;

// ✅ 50ms마다 도는 tick 안쪽 상세 이벤트 (pendingSeek, drift align 등)
const bool kSmpVideoSyncLogTick = false;

void _logSmpVideo(String message, {bool tick = false}) {
  if (tick) {
    if (!kSmpVideoSyncLogTick) return;
  } else {
    if (!kSmpVideoSyncLogBasic) return;
  }
  debugPrint('[SMP/VideoSync] $message');
}

class VideoSyncService {
  VideoSyncService._();
  static final VideoSyncService instance = VideoSyncService._();

  VideoController? _vc;
  Player? _player;
  Timer? _syncTimer;
  DateTime? _lastAlignAt;

  // ============================================================
  // CONSTS (A/V Sync Parameters)
  // ============================================================

  /// 싱크 체크 주기 (Hybrid APlan 예시 기준: 50ms)
  static const Duration _tickInterval = Duration(milliseconds: 50);

  /// 실제 강제 보정이 일어나는 드리프트 기준 (|video - audio| > 100ms)
  static const int _hardDriftMs = 100;

  /// 논리적 목표 오차 범위(±50ms). 현재 코드는 하드 기준만 사용하지만,
  /// 디버깅/로깅 용도로 남겨둠.
  static const int _softDriftMs = 50;

  // ============================================================
  // PUBLIC GETTERS
  // ============================================================
  VideoController? get controller => _vc;
  bool get isVideoLoaded => _vc != null;

  Duration get videoPosition => _player?.state.position ?? Duration.zero;

  // ============================================================
  // ATTACH PLAYER
  // ============================================================
  Future<void> attachPlayer(Player player) async {
    _player = player;
    _vc = VideoController(player);

    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_tickInterval, (_) => _tick());

    _logSmpVideo(
      'attachPlayer(): start sync timer every ${_tickInterval.inMilliseconds}ms',
    );
  }

  // ============================================================
  // INTERNAL DRIFT CORRECTION
  // ============================================================
  Future<void> _tick() async {
    final p = _player;
    if (p == null) return;

    final engine = EngineApi.instance;

    // duration(SoT 축)이 아직 정해지지 않았으면 아무것도 하지 않음
    if (engine.duration <= Duration.zero) {
      return;
    }

    // 1) pendingSeekTarget 우선 소비
    final pendingSeek = engine.pendingSeekTarget;
    if (pendingSeek != null) {
      engine.pendingSeekTarget = null;
      try {
        _logSmpVideo(
          '_tick(): consume pendingSeekTarget=${pendingSeek.inMilliseconds}ms',
          tick: true,
        );
        await p.seek(pendingSeek);
        _lastAlignAt = DateTime.now();
      } catch (_) {
        _logSmpVideo(
          '_tick(): pendingSeekTarget seek failed (ignored)',
          tick: true,
        );
      }
      return;
    }

    // 2) pendingAlignTarget 소비
    final pendingAlign = engine.pendingAlignTarget;
    if (pendingAlign != null) {
      engine.pendingAlignTarget = null;
      try {
        _logSmpVideo(
          '_tick(): consume pendingAlignTarget=${pendingAlign.inMilliseconds}ms',
          tick: true,
        );
        await p.seek(pendingAlign);
        _lastAlignAt = DateTime.now();
      } catch (_) {
        _logSmpVideo(
          '_tick(): pendingAlignTarget seek failed (ignored)',
          tick: true,
        );
      }
      return;
    }

    // 3) 주기(throttle) 체크
    final now = DateTime.now();
    if (_lastAlignAt != null && now.difference(_lastAlignAt!) < _tickInterval) {
      return;
    }

    // 4) FFmpeg SoT(EngineApi.position) 기준 drift 계산
    try {
      final audioPos = engine.position; // 이미 EngineApi에서 [0, duration]으로 클램프됨
      final videoPos = p.state.position;

      final diffMs = (videoPos - audioPos).inMilliseconds;

      if (diffMs.abs() > _hardDriftMs) {
        _logSmpVideo(
          '_tick(): drift=${diffMs}ms (soft=$_softDriftMs, hard=$_hardDriftMs) → align video to audioPos=${audioPos.inMilliseconds}ms (videoPos=${videoPos.inMilliseconds}ms)',
          tick: true,
        );
        await p.seek(audioPos);
        _lastAlignAt = DateTime.now();
      }
    } catch (_) {
      _logSmpVideo(
        '_tick(): exception while checking drift (ignored)',
        tick: true,
      );
    }
  }

  // ============================================================
  // PUBLIC ALIGN
  // ============================================================
  Future<void> align(Duration d) async {
    final p = _player;
    if (p == null) return;

    final engine = EngineApi.instance;
    final now = DateTime.now();

    if (_lastAlignAt != null && now.difference(_lastAlignAt!) < _tickInterval) {
      _logSmpVideo(
        'align($d): throttled, lastAlignAt=${_lastAlignAt!.toIso8601String()}',
      );
      return;
    }

    // SoT 축 기준으로 한 번 더 클램프
    Duration target = d;
    final dur = engine.duration;
    if (dur > Duration.zero) {
      if (target < Duration.zero) target = Duration.zero;
      if (target > dur) target = dur;
    }

    _lastAlignAt = now;

    try {
      _logSmpVideo(
        'align($d): seek video to ${target.inMilliseconds}ms (dur=${dur.inMilliseconds}ms)',
      );
      await p.seek(target);
    } catch (_) {
      _logSmpVideo('align($d): seek failed (ignored)');
    }
  }

  // ============================================================
  // DISPOSE
  // ============================================================
  Future<void> dispose() async {
    _logSmpVideo('dispose(): stop sync timer & clear controller/player');
    _syncTimer?.cancel();
    _syncTimer = null;
    _vc = null;
    _player = null;
    _lastAlignAt = null;
  }
}
