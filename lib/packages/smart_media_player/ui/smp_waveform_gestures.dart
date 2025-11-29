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
// FFmpeg SoT 기반 엔진(EngineApi.position/duration)과의 연동을 위해
// - seek 제스처 시 waveform.recordSeekTimestamp() 호출
// - viewport(viewStart/viewWidth) 기준으로 시간 매핑(_toTime / hit-test)
// 을 적용함.
//
// P2/P3 규칙:
//  - 이 레벨에서는 StartCue/Loop를 "표시/콜백 전달"만 담당
//  - StartCue/Loop를 기준으로 시킹을 막거나 clamp하지 않는다.
//  - 엔진 SoT(position$)는 Screen → WaveformController로 단일 진입점이며,
//    필요 시 setPosition()으로 제스처 레벨에서 참조만 한다.
//  - drag/스크럽/FF/FR로 이동하는 위치는 항상 0ms ~ duration 범위로만 clamp한다.
//

import 'package:flutter/material.dart';
import 'package:guitartree/packages/smart_media_player/waveform/system/waveform_system.dart';

enum GestureMode {
  idle,
  scrubbing,
  loopA,
  loopB,
  selecting,
  zooming,
  pinchZooming,
  wheelZooming,
}

class SmpWaveformGestures {
  // ===== Dependencies from Screen =====
  final WaveformController waveform;

  final Duration Function() getDuration;
  final Duration Function() getStartCue;

  // 화면의 상태 변경 함수
  final void Function(Duration) setStartCue;

  // 🟢 P3: Screen 콜백은 내부 전용 핸들로 보관
  final void Function(Duration) _setPositionCallback;

  // 실제 엔진 seek 호출
  final Future<void> Function(Duration) onSeekRequest;

  // 일시정지 콜백 (EngineApi.pause는 screen.dart에서 주입)
  final VoidCallback onPause;

  // 디바운스 저장
  final void Function({bool saveMemo}) saveDebounced;

  // 리스너 핸들
  VoidCallback? _loopOnListener;
  VoidCallback? _markersListener;

  bool _attached = false;

  SmpWaveformGestures({
    required this.waveform,
    required this.getDuration,
    required this.getStartCue,
    required this.setStartCue,
    // 🟢 P3: Screen에서 넘겨주는 setPosition 콜백은
    //        내부 핸들(_setPositionCallback)로만 보관한다.
    required void Function(Duration) setPosition,
    required this.onSeekRequest,
    required this.onPause,
    required this.saveDebounced,
  }) : _setPositionCallback = setPosition;

  // ===== Pinch Zoom State =====
  double? _pinchOriginFrac;
  double _lastScale = 1.0;
  DateTime? _lastPinchAt;

  GestureMode _mode = GestureMode.idle;

  GestureMode get mode => _mode;

  // ===============================================================
  // Handle HitTest (Loop A/B, Selection) — 필요 시 Panel에서 사용
  // ===============================================================
  bool hitLoopA(double globalFrac) => _hitLoopA(globalFrac);
  bool hitLoopB(double globalFrac) => _hitLoopB(globalFrac);
  bool hitSelection(double globalFrac) => _hitSelection(globalFrac);

  bool _hitLoopA(double globalFrac) {
    final a = waveform.loopA.value;
    if (a == null) return false;
    final dur = getDuration();
    if (dur <= Duration.zero) return false;

    final aFrac = a.inMilliseconds / dur.inMilliseconds;
    return (globalFrac - aFrac).abs() < 0.015; // 1.5% 화면폭 히트박스
  }

  bool _hitLoopB(double globalFrac) {
    final b = waveform.loopB.value;
    if (b == null) return false;
    final dur = getDuration();
    if (dur <= Duration.zero) return false;

    final bFrac = b.inMilliseconds / dur.inMilliseconds;
    return (globalFrac - bFrac).abs() < 0.015;
  }

  bool _hitSelection(double globalFrac) {
    final a = waveform.selectionA.value;
    final b = waveform.selectionB.value;
    if (a == null || b == null) return false;

    final dur = getDuration();
    if (dur <= Duration.zero) return false;

    final aFrac = a.inMilliseconds / dur.inMilliseconds;
    final bFrac = b.inMilliseconds / dur.inMilliseconds;

    final minF = aFrac < bFrac ? aFrac : bFrac;
    final maxF = aFrac > bFrac ? aFrac : bFrac;

    return globalFrac >= minF && globalFrac <= maxF;
  }

  // ===============================================================
  // attach() — 화면 initState()에서 호출
  // ===============================================================
  void attach() {
    if (_attached) return;
    _attached = true;

    // ----- Seek -----
    waveform.onSeek = (Duration d) {
      _handleSeekFromGesture(d);
    };

    // ----- Pause -----
    waveform.onPause = onPause;

    // ----- Loop A/B 설정 -----
    waveform.onLoopSet = (a, b) {
      _handleLoopSetFromGesture(a, b);
    };

    // ----- Start Cue 설정 -----
    waveform.onStartCueSet = (Duration t) {
      _handleStartCueFromGesture(t);
    };

    // ----- Controller Value Listeners (loopOn / markers / viewport) -----
    _bindValueListeners();
    _bindViewportListeners();
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
    waveform.onPause = null;
  }

  // ===============================================================
  // Drag 상태 관리
  // ===============================================================

  void onDragStart() {
    _mode = GestureMode.scrubbing;
    // drag 시작 시 저장 금지 (필요 시 onPause 호출 가능)
  }

  void onDragEnd() {
    _mode = GestureMode.idle;
    // drag 종료 시 단 1회 저장
    saveDebounced(saveMemo: false);
  }

  // ===============================================================
  // Seek from Gesture → clamp(0~duration) + SoT race guard
  // ===============================================================
  void _handleSeekFromGesture(Duration d) {
    // 0 ~ duration 범위로 clamp
    final dur = getDuration();
    Duration target = d;

    if (dur > Duration.zero) {
      if (target.isNegative) {
        target = Duration.zero;
      } else if (target > dur) {
        target = dur;
      }
    } else {
      if (target.isNegative) {
        target = Duration.zero;
      }
    }

    // FFmpeg SoT 기반 seek 시, 엔진 position 스트림의 오래된 값 무시를 위해
    // 먼저 timestamp 기록
    waveform.recordSeekTimestamp();

    // UI 즉시 반영
    waveform.position.value = target;

    // Screen 콜백에도 전달 (현재는 no-op이지만 시그니처 유지)
    _setPositionCallback(target);

    // Engine seek 요청 (비동기)
    onSeekRequest(target);
  }

  // ===============================================================
  // 2) Loop 설정(a,b) → UI단에서 viewport 조정/저장만 담당
  // ===============================================================
  void _handleLoopSetFromGesture(Duration? a, Duration? b) {
    // 화면에서 loopA/B는 screen.dart가 setState()로 처리
    // 이곳은 viewport/저장 등 보조 로직만 담당
    saveDebounced(saveMemo: false);
  }

  // ===============================================================
  // 3) StartCue 설정
  // ===============================================================
  void _handleStartCueFromGesture(Duration t) {
    // P2/P3: StartCue는 loop와 독립 — 여기서는 단순 전달만
    setStartCue(t);
    saveDebounced(saveMemo: false);
  }

  // ===============================================================
  // 3-B) Screen → Gestures SoT 동기화 진입점
  //
  //  - Screen 쪽 EngineApi.position$ 리스너에서 호출됨
  //  - 현재 구조에서는 WaveformController.updateFromPlayer()가
  //    이미 SoT를 관장하므로, 여기서는 position Value만 정렬해 둔다.
  //  - 필요 시 GestureMode(scrubbing 등)에 따라 필터링 확장 가능.
  // ===============================================================
  void setPosition(Duration pos) {
    // 엔진에서 넘어온 SoT도 안전하게 0~duration 범위로 정리
    final dur = getDuration();
    Duration target = pos;

    if (dur > Duration.zero) {
      if (target.isNegative) {
        target = Duration.zero;
      } else if (target > dur) {
        target = dur;
      }
    } else {
      if (target.isNegative) {
        target = Duration.zero;
      }
    }

    waveform.position.value = target;
  }

  // ===============================================================
  // 4) Zoom / Viewport
  // ===============================================================
  // Zoom with Origin (Alt + Drag / Pinch)
  // cursorFrac: 0.0 ~ 1.0 (화면 좌표 → waveform 상대 좌표)
  // factor: >1 확대 / <1 축소
  // ===============================================================
  void zoomAt({required double cursorFrac, required double factor}) {
    _isZooming = true;

    try {
      final dur = getDuration();
      if (dur <= Duration.zero) return;

      // 안정화
      if (factor > 1.2) factor = 1.2;
      if (factor < 0.8) factor = 0.8;
      if (factor > 0.98 && factor < 1.02) return;

      double norm(double v) => double.parse(v.toStringAsFixed(8));

      final oldStart = waveform.viewStart.value;
      final oldWidth = waveform.viewWidth.value;

      double newWidth = norm((oldWidth / factor).clamp(0.001, 1.0));
      double newStart = norm(cursorFrac - (cursorFrac - oldStart) / factor);

      if (newStart < 0.0) newStart = 0.0;
      if (newStart + newWidth > 1.0) {
        newStart = norm(1.0 - newWidth);
        if (newStart < 0.0) newStart = 0.0;
      }

      waveform.setViewport(start: newStart, width: newWidth);
    } finally {
      _isZooming = false;
    }

    saveDebounced(saveMemo: false);
  }

  // zoom 중 충돌 방지 플래그
  bool _isZooming = false;

  void zoomReset() {
    final dur = getDuration();
    if (dur <= Duration.zero) return;
    waveform.setViewport(start: 0.0, width: 1.0);
    saveDebounced(saveMemo: false);
  }

  // ===============================================================
  // 5) WaveformController Value Listeners
  // ===============================================================
  void _bindValueListeners() {
    // ===== loopOn =====
    _loopOnListener = () {
      if (_isZooming) return; // drag/zoom 충돌 방지
      saveDebounced(saveMemo: false);
    };
    waveform.loopOn.addListener(_loopOnListener!);

    // ===== markers =====
    _markersListener = () {
      if (_isZooming) return; // zoom 중 marker 튐 방지
      saveDebounced(saveMemo: false);
    };
    waveform.markers.addListener(_markersListener!);
  }

  // ===============================================================
  // 5-A) Controller → Gestures 양방향 동기화 (viewport)
  // ===============================================================
  void _bindViewportListeners() {
    waveform.viewStart.addListener(() {
      // 필요 시 viewport 변경에 따른 추가 처리 가능
    });
    waveform.viewWidth.addListener(() {
      // 필요 시 viewport 변경에 따른 추가 처리 가능
    });
  }

  // ===============================================================
  // Pinch Start — cursorFrac 고정
  // ===============================================================
  void onPinchStart({required double localX, required double widthPx}) {
    if (widthPx <= 0) return;

    _mode = GestureMode.pinchZooming;

    // 화면 비율로 변환 (0~1, viewport 상대 좌표)
    final frac = (localX / widthPx).clamp(0.0, 1.0);
    _pinchOriginFrac = frac;
    _lastScale = 1.0;
    _lastPinchAt = DateTime.now();
  }

  // ===============================================================
  // Pinch Update — deltaScale 안정화 + zoomAt 연동
  // ===============================================================
  void onPinchUpdate(double scale) {
    if (_pinchOriginFrac == null) return;

    // delta = 현재 scale / 직전 scale
    double delta = scale / _lastScale;

    // ===== 안정화 필터 =====
    // 지나치게 튀는 scale 제거
    if (delta > 1.2) delta = 1.2;
    if (delta < 0.8) delta = 0.8;

    // micro jitter 제거 (1.0 근처 dead-zone)
    if (delta > 0.98 && delta < 1.02) {
      _lastScale = scale;
      return;
    }

    // zoomAt 호출
    zoomAt(cursorFrac: _pinchOriginFrac!, factor: delta);

    _lastScale = scale;
    _lastPinchAt = DateTime.now();
  }

  // ===============================================================
  // Pinch End — origin 초기화
  // ===============================================================
  void onPinchEnd() {
    _mode = GestureMode.idle;
    _pinchOriginFrac = null;
    _lastScale = 1.0;
    _lastPinchAt = null;
  }
}
