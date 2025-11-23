// lib/packages/smart_media_player/ui/smp_waveform_gestures.dart
// v3.41 — Step 2-6 Waveform Gesture / Zoom / Viewport / Seek / Marker Sync 완전 분리본
//
// 💡 SmartMediaPlayerScreen에서 직접 하던 다음 책임 전부 이 파일로 이전됨:
//  - waveform.onSeek / onLoopSet / onStartCueSet
//  - viewport(viewStart/viewWidth) 계산
//  - zoom in/out/reset
//  - drag/스크럽 기반 UI-level seek 동작
//  - loopOn / markers value listeners
//
// screen.dart가 가지는 책임은 이제:
//  - setState()로 화면 상태 업데이트
//  - 실제 엔진(player.seek) 호출
//  - sidecar 저장
// 만 담당함.
//
// ===============================================================

import 'package:flutter/material.dart';
import 'package:guitartree/packages/smart_media_player/waveform/system/waveform_system.dart';
import 'package:guitartree/packages/smart_media_player/engine/engine_api.dart';


class SmpWaveformGestures {
  // ===== Dependencies from Screen =====
  final WaveformController waveform;

  final Duration Function() getDuration;
  final Duration Function() getStartCue;

  // 화면의 상태 변경 함수
  final void Function(Duration) setStartCue;
  final void Function(Duration) setPosition;

  // 실제 엔진 seek 호출
  final Future<void> Function(Duration) onSeekRequest;

  // 디바운스 저장
  final void Function({bool saveToDb}) saveDebounced;

  // ===== Local State =====
  double viewStart = 0.0;
  double viewWidth = 1.0;

  // 리스너 핸들
  VoidCallback? _loopOnListener;
  VoidCallback? _markersListener;

  bool _attached = false;

  SmpWaveformGestures({
    required this.waveform,
    required this.getDuration,
    required this.getStartCue,
    required this.setStartCue,
    required this.setPosition,
    required this.onSeekRequest,
    required this.saveDebounced,
  });

  // ===============================================================
  // attach() — 화면 initState()에서 호출
  // ===============================================================
  void attach() {
    if (_attached) return;
    _attached = true;

    // ----- Seek -----
    waveform.onSeek = (Duration d) {
      _handleSeekFromGesture(d);
      waveform.onPause = () {
        EngineApi.instance.pause();
      };
    };

    // ----- Loop A/B 설정 -----
    waveform.onLoopSet = (Duration? a, Duration? b) {
      _handleLoopSetFromGesture(a, b);
    };

    // ----- Start Cue 설정 -----
    waveform.onStartCueSet = (Duration t) {
      _handleStartCueFromGesture(t);
    };

    // ----- Controller Value Listeners (loopOn / markers) -----
    _bindValueListeners();
  }

  // ===============================================================
  // dispose() — 화면 dispose()에서 호출
  // ===============================================================
  void dispose() {
    if (!_attached) return;
    _attached = false;

    // 리스너 정리
    if (_loopOnListener != null) {
      waveform.loopOn.removeListener(_loopOnListener!);
    }
    if (_markersListener != null) {
      waveform.markers.removeListener(_markersListener!);
    }

    // 콜백 제거
    waveform.onSeek = null;
    waveform.onLoopSet = null;
    waveform.onStartCueSet = null;
  }

  // ===============================================================
  // Drag 상태 관리 — Step 5-4
  // ===============================================================

  void onDragStart() {
    // drag 시작 시 저장 금지
  }

  void onDragEnd() {
    // drag 종료 시 단 1회 저장
    saveDebounced(saveToDb: false);
  }

  void _handleSeekFromGesture(Duration d) {
    // drag 중 seeks → 저장 금지
    waveform.position.value = d;
    setPosition(d);
    onSeekRequest(d);
  }
  // ===============================================================
  // 2) Loop 설정(a,b) → UI단에서 viewport 조정만 담당
  // ===============================================================
  void _handleLoopSetFromGesture(Duration? a, Duration? b) {
    // 화면에서 loopA/B는 screen.dart가 setState()로 처리
    // 이곳은 viewport 처리 필요 시 확장 가능
    saveDebounced(saveToDb: false);
  }

  // ===============================================================
  // 3) StartCue 설정
  // ===============================================================
  void _handleStartCueFromGesture(Duration t) {
    setStartCue(t);
    saveDebounced(saveToDb: false);
  }

  // ===============================================================
  // 4) Zoom / Viewport
  // ===============================================================
  void zoom(double factor) {
    const maxWidth = 1.0;

    // 현재 시작점의 비율
    final centerFrac = (viewStart + viewWidth / 2).clamp(0.0, 1.0);

    // 새 width
    final newWidth = (viewWidth / factor).clamp(
      1.0 / 50.0, // zoom max = 50x
      maxWidth,
    );

    // start = 시작점을 중앙 근처로 유지하는 방식
    final newStart = (centerFrac - newWidth / 2).clamp(
      0.0,
      (1.0 - newWidth).clamp(0.0, 1.0),
    );


    viewWidth = newWidth;
    viewStart = newStart;

    waveform.setViewport(start: viewStart, width: viewWidth);
    saveDebounced(saveToDb: false); // 5-4: zoom은 이벤트이므로 1회 저장
  }

    void zoomReset() {
    viewStart = 0.0;
    viewWidth = 1.0;
    waveform.setViewport(start: viewStart, width: viewWidth);
    saveDebounced(saveToDb: false); // 5-4 추가
  }


  // ===============================================================
  // 5) WaveformController Value Listeners
  // ===============================================================
  void _bindValueListeners() {
    // ===== loopOn =====
    _loopOnListener = () {
      // loopOn UI만 반영 (screen.dart가 실제 A/B/Enabled 저장)
      saveDebounced(saveToDb: false);
    };
    waveform.loopOn.addListener(_loopOnListener!);

    // ===== markers =====
    _markersListener = () {
      // markers는 화면(screen)에서 MarkerPoint로 재구성하므로
      // 여기서는 “변함 있음” 신호만 줌
      saveDebounced(saveToDb: false);
    };
    waveform.markers.addListener(_markersListener!);
  }
}
