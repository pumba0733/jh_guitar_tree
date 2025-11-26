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
// ===============================================================

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
  final void Function(Duration) setPosition;

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
    required this.setPosition,
    required this.onSeekRequest,
    required this.onPause,
    required this.saveDebounced,
  });

  // ===== Pinch Zoom State =====
  double? _pinchOriginFrac;
  double _lastScale = 1.0;
  DateTime? _lastPinchAt;

  GestureMode _mode = GestureMode.idle;

  // ===============================================================
  // Handle HitTest (Loop A/B, Selection)
  // ===============================================================
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
    // 타입 추론 사용해서 WaveformController.onLoopSet과 일치
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
  // Drag 상태 관리 — Step 5-4
  // ===============================================================

  void onDragStart() {
    // drag 시작 시 저장 금지 (필요 시 onPause 호출 가능)
  }

  void onDragEnd() {
    // drag 종료 시 단 1회 저장
    saveDebounced(saveMemo: false);
  }

  void _handleSeekFromGesture(Duration d) {
    // FFmpeg SoT 기반 seek 시, 엔진 position 스트림의 오래된 값 무시를 위해
    // 먼저 timestamp 기록
    waveform.recordSeekTimestamp();

    // UI 즉시 반영
    waveform.position.value = d;
    setPosition(d);

    // Engine seek 요청 (비동기)
    onSeekRequest(d);
  }

  // ===============================================================
  // 2) Loop 설정(a,b) → UI단에서 viewport 조정만 담당
  // ===============================================================
  void _handleLoopSetFromGesture(Duration? a, Duration? b) {
    // 화면에서 loopA/B는 screen.dart가 setState()로 처리
    // 이곳은 viewport 처리 필요 시 확장 가능
    saveDebounced(saveMemo: false);
  }

  // ===============================================================
  // 3) StartCue 설정
  // ===============================================================
  void _handleStartCueFromGesture(Duration t) {
    setStartCue(t);
    saveDebounced(saveMemo: false);
  }

  // ===============================================================
  // 4) Zoom / Viewport
  // ===============================================================
  // Zoom with Origin (Alt + Drag / Pinch) — Step 7-2
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

  // Step 7-2 Patch 5-C: prevent marker/loop/startCue override during zoom
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
  // 5-A) Controller → Gestures 양방향 동기화 (Step 6-B)
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
    _pinchOriginFrac = null;
    _lastScale = 1.0;
  }

  // ===============================================================
  // Wheel Zoom — macOS 지원
  // ===============================================================
  void onWheelZoom({
    required double deltaY,
    required double localX,
    required double widthPx,
  }) {
    // deltaY > 0 → zoom out, deltaY < 0 → zoom in
    double factor = deltaY < 0 ? 1.05 : 0.95;

    final frac = (localX / widthPx).clamp(0.0, 1.0);
    zoomAt(cursorFrac: frac, factor: factor);
  }

  void onLoopDragUpdate({required double localX, required double widthPx}) {
    autoScrollDuringDrag(localX, widthPx);
  }

  void autoScrollDuringDrag(double localX, double widthPx) {
    if (widthPx <= 0) return;

    final fracView = (localX / widthPx).clamp(0.0, 1.0);
    final vStart = waveform.viewStart.value;
    final vWidth = waveform.viewWidth.value;

    const edge = 0.12;
    const step = 0.03; // DAW-level scroll step

    if (fracView > (1.0 - edge)) {
      // 오른쪽 끝 → 오른쪽으로 autoscroll
      final newStart = (vStart + vWidth * step).clamp(0.0, 1.0 - vWidth);
      waveform.setViewport(start: newStart, width: vWidth);
    } else if (fracView < edge) {
      // 왼쪽 끝 → 왼쪽으로 autoscroll
      final newStart = (vStart - vWidth * step).clamp(0.0, 1.0 - vWidth);
      waveform.setViewport(start: newStart, width: vWidth);
    }
  }

  void onPointerDown({
    required double localX,
    required double widthPx,
    bool altKey = false,
    bool shiftKey = false,
  }) {
    if (widthPx <= 0) return;

    // 뷰포트 상대 좌표(0~1)
    final fracView = (localX / widthPx).clamp(0.0, 1.0);
    final vStart = waveform.viewStart.value;
    final vWidth = waveform.viewWidth.value.clamp(0.0001, 1.0);

    // 전체 타임라인(global)에서의 비율
    final globalFrac = (vStart + vWidth * fracView).clamp(0.0, 1.0);

    // ===== 1) 핀치/휠 모드 선점 =====
    if (_mode == GestureMode.pinchZooming ||
        _mode == GestureMode.wheelZooming) {
      return;
    }

    // ===== 2) Alt + Drag → Zoom 모드 =====
    if (altKey) {
      _mode = GestureMode.zooming;
      return;
    }

    // ===== 3) Loop A Handle =====
    if (_hitLoopA(globalFrac)) {
      _mode = GestureMode.loopA;
      return;
    }

    // ===== 4) Loop B Handle =====
    if (_hitLoopB(globalFrac)) {
      _mode = GestureMode.loopB;
      return;
    }

    // ===== 5) Shift → Selection =====
    if (shiftKey) {
      _mode = GestureMode.selecting;
      waveform.selectionA.value = _toTime(localX, widthPx);
      waveform.selectionB.value = _toTime(localX, widthPx);
      return;
    }

    // ===== 6) Default → Scrubbing =====
    _mode = GestureMode.scrubbing;
  }

  void onPointerMove({required double localX, required double widthPx}) {
    // Zoom 모드는 drag/scrub과 구분
    if (_mode == GestureMode.zooming) {
      // zoomAt은 외부 제스처에서 호출됨
      return;
    }

    if (_mode == GestureMode.pinchZooming ||
        _mode == GestureMode.wheelZooming) {
      return;
    }

    switch (_mode) {
      case GestureMode.scrubbing:
        _handleSeekDrag(localX, widthPx);
        break;
      case GestureMode.loopA:
        _handleLoopADrag(localX, widthPx);
        break;
      case GestureMode.loopB:
        _handleLoopBDrag(localX, widthPx);
        break;
      case GestureMode.selecting:
        _handleSelectingDrag(localX, widthPx);
        break;
      default:
        break;
    }
  }

  void onPointerUp() {
    if (_mode == GestureMode.scrubbing ||
        _mode == GestureMode.loopA ||
        _mode == GestureMode.loopB ||
        _mode == GestureMode.selecting) {
      saveDebounced(saveMemo: false);
    }

    _mode = GestureMode.idle;
    _isZooming = false;
  }

  Duration _toTime(double localX, double widthPx) {
    if (widthPx <= 0) return Duration.zero;

    final dur = getDuration();
    if (dur <= Duration.zero) return Duration.zero;

    // 뷰포트 상대 비율
    final fracView = (localX / widthPx).clamp(0.0, 1.0);
    final vStart = waveform.viewStart.value;
    final vWidth = waveform.viewWidth.value.clamp(0.0001, 1.0);

    // 전체 타임라인(global)에서의 비율
    final globalFrac = (vStart + vWidth * fracView).clamp(0.0, 1.0);

    return Duration(milliseconds: (dur.inMilliseconds * globalFrac).toInt());
  }

  void _handleSeekDrag(double localX, double widthPx) {
    final t = _toTime(localX, widthPx);

    // FFmpeg SoT seek와 race 방지용 timestamp 기록
    waveform.recordSeekTimestamp();

    waveform.position.value = t;
    setPosition(t);
    onSeekRequest(t);
  }

  void _handleLoopADrag(double localX, double widthPx) {
    final t = _toTime(localX, widthPx);

    // A 지점만 이동
    final oldA = waveform.loopA.value;
    final oldB = waveform.loopB.value;

    // B보다 뒤로 못 가도록 clamp
    Duration newA = t;
    if (oldB != null && newA > oldB) {
      newA = oldB;
    }

    waveform.loopA.value = newA;

    // 필요 시 오토 스크롤
    autoScrollDuringDrag(localX, widthPx);
  }

  void _handleLoopBDrag(double localX, double widthPx) {
    final t = _toTime(localX, widthPx);

    // B 지점만 이동
    final oldA = waveform.loopA.value;
    final oldB = waveform.loopB.value;

    // A보다 앞으로 못 가도록 clamp
    Duration newB = t;
    if (oldA != null && newB < oldA) {
      newB = oldA;
    }

    waveform.loopB.value = newB;

    // 필요 시 오토 스크롤
    autoScrollDuringDrag(localX, widthPx);
  }

  void _handleSelectingDrag(double localX, double widthPx) {
    final t = _toTime(localX, widthPx);

    final start = waveform.selectionA.value;

    // selection 시작점이 없으면 지금이 시작점
    if (start == null) {
      waveform.selectionA.value = t;
      waveform.selectionB.value = t;
    } else {
      waveform.selectionB.value = t;
    }

    autoScrollDuringDrag(localX, widthPx);
  }
}
