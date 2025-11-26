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
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../engine/engine_api.dart';

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
  }

  // ============================================================
  // INTERNAL DRIFT CORRECTION
  // ============================================================
  Future<void> _tick() async {
    final p = _player;
    if (p == null) return;

    final engine = EngineApi.instance;

    // 1) pendingSeekTarget 우선 소비
    //
    //    엔진에서 unified seek가 발생했을 때:
    //      - 오디오는 이미 FFmpeg 엔진이 해당 위치로 seek 완료
    //      - VideoSyncService는 이 값을 소비해 mpv를 한 번에 맞춘다.
    final pendingSeek = engine.pendingSeekTarget;
    if (pendingSeek != null) {
      engine.pendingSeekTarget = null;
      try {
        await p.seek(pendingSeek);
        _lastAlignAt = DateTime.now();
      } catch (_) {
        // 비디오가 없거나 seek 실패해도 오디오는 이미 맞아 있으므로 무시
      }
      return; // 이 tick에서는 추가 보정 하지 않고 종료
    }

    // 2) pendingAlignTarget 소비
    //
    //    loop 재진입 / StartCue 이동 등에서 "해당 위치로 비디오만 강제 정렬"
    //    이 필요한 경우 사용되는 훅.
    final pendingAlign = engine.pendingAlignTarget;
    if (pendingAlign != null) {
      engine.pendingAlignTarget = null;
      try {
        await p.seek(pendingAlign);
        _lastAlignAt = DateTime.now();
      } catch (_) {
        // 실패 시에도 다음 tick에서 일반 drift 보정이 작동하므로 치명적이지 않다.
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
      // 오디오 절대 시간(FFmpeg SoT)
      final audioPos = engine.position;
      final videoPos = p.state.position;

      final diffMs = (videoPos - audioPos).inMilliseconds;

      // |diff|가 하드 기준(100ms)을 넘을 때만 비디오를 오디오에 맞춘다.
      if (diffMs.abs() > _hardDriftMs) {
        await p.seek(audioPos);
        _lastAlignAt = DateTime.now();
      }
    } catch (_) {
      // 엔진이 아직 초기화 중이거나 파일이 없을 때 발생할 수 있는 예외는 무시
    }
  }

  // ============================================================
  // PUBLIC ALIGN
  // ============================================================
  //
  // 외부에서 특정 시점으로 비디오를 강제 정렬하고 싶을 때 사용하는 헬퍼.
  // (예: 초기 load 직후 0ms 정렬, 특정 QA 도구 등)
  //
  // EngineApi.position이 이미 목표 시점을 반영하고 있다면
  // _tick()의 drift 보정만으로도 충분하지만,
  // 명시적으로 한 번에 맞추고 싶은 경우에 사용.
  Future<void> align(Duration d) async {
    final p = _player;
    if (p == null) return;

    final now = DateTime.now();
    if (_lastAlignAt != null && now.difference(_lastAlignAt!) < _tickInterval) {
      return;
    }
    _lastAlignAt = now;

    try {
      await p.seek(d);
    } catch (_) {
      // seek 실패는 치명적이지 않음. 다음 tick에서 다시 보정 기회를 가진다.
    }
  }

  // ============================================================
  // DISPOSE
  // ============================================================
  Future<void> dispose() async {
    _syncTimer?.cancel();
    _syncTimer = null;
    _vc = null;
    _player = null;
    _lastAlignAt = null;
  }
}
