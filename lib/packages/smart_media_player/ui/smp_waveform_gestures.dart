// lib/packages/smart_media_player/ui/smp_waveform_gestures.dart
// v3.41 — Step 2-6 Waveform Gesture / Zoom / Viewport / Seek / Marker Sync 완전 분리본
//
// ...

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

  // 🔥 현재 재생 여부 (정지 상태 drag/클릭 분기용)
  final bool Function() isPlaying;

  VoidCallback? _loopOnListener;
  VoidCallback? _markersListener;

  bool _attached = false;

  bool _isDragging = false;
  Duration? _dragStartPos;
  Duration? _dragLastPos;

  SmpWaveformGestures({
    required this.waveform,
    required this.getDuration,
    required this.getStartCue,
    required this.setStartCue,
    required void Function(Duration) setPosition,
    required this.onSeekRequest,
    required this.onPause,
    required this.saveDebounced,
    required this.isPlaying,
  }) : _setPositionCallback = setPosition;

  // ===== Pinch Zoom State =====
  double? _pinchOriginFrac;
  double _lastScale = 1.0;
  DateTime? _lastPinchAt;

  GestureMode _mode = GestureMode.idle;

  GestureMode get mode => _mode;

  bool hitLoopA(double globalFrac) => _hitLoopA(globalFrac);
  bool hitLoopB(double globalFrac) => _hitLoopB(globalFrac);
  bool hitSelection(double globalFrac) => _hitSelection(globalFrac);

  bool _hitLoopA(double globalFrac) {
    final a = waveform.loopA.value;
    if (a == null) return false;
    final dur = getDuration();
    if (dur <= Duration.zero) return false;

    final aFrac = a.inMilliseconds / dur.inMilliseconds;
    return (globalFrac - aFrac).abs() < 0.015;
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

  void attach() {
    if (_attached) return;
    _attached = true;

    waveform.onSeek = (Duration d) {
      _handleSeekFromGesture(d);
    };

    waveform.onPause = onPause;

    waveform.onLoopSet = (a, b) {
      _handleLoopSetFromGesture(a, b);
    };

    waveform.onStartCueSet = (Duration t) {
      _handleStartCueFromGesture(t);
    };

    _bindValueListeners();
    _bindViewportListeners();
  }

  void dispose() {
    if (!_attached) return;
    _attached = false;

    if (_loopOnListener != null) {
      waveform.loopOn.removeListener(_loopOnListener!);
    }
    if (_markersListener != null) {
      waveform.markers.removeListener(_markersListener!);
    }

    waveform.onSeek = null;
    waveform.onLoopSet = null;
    waveform.onStartCueSet = null;
    waveform.onPause = null;
  }

  void onDragStart({required Duration anchor}) {
    _mode = GestureMode.scrubbing;
    _isDragging = true;

    _dragStartPos = anchor;
    _dragLastPos = null;
  }

  void onDragEnd() {
    _mode = GestureMode.idle;
    _isDragging = false;

    if (_dragStartPos != null && _dragLastPos != null) {
      final a = _dragStartPos!;
      final b = _dragLastPos!;
      final startCueCandidate = a <= b ? a : b;

      setStartCue(startCueCandidate);
      saveDebounced(saveMemo: false);
    }

    _dragStartPos = null;
    _dragLastPos = null;
  }

  void _handleSeekFromGesture(Duration d) {
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

    final playing = isPlaying();

    if (!playing) {
      if (_isDragging) {
        _dragLastPos = target;
      }
      return;
    }

    if (!_isDragging) {
      waveform.recordSeekTimestamp();
      waveform.position.value = target;
      _setPositionCallback(target);

      onSeekRequest(target);

      saveDebounced(saveMemo: false);
      return;
    }

    _dragLastPos = target;

    waveform.recordSeekTimestamp();
    waveform.position.value = target;
    _setPositionCallback(target);

    onSeekRequest(target);
  }

  void _handleLoopSetFromGesture(Duration? a, Duration? b) {
    saveDebounced(saveMemo: false);
  }

  void _handleStartCueFromGesture(Duration t) {
    setStartCue(t);
    saveDebounced(saveMemo: false);
  }

  void setPosition(Duration pos) {
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

  void zoomAt({required double cursorFrac, required double factor}) {
    _isZooming = true;

    try {
      final dur = getDuration();
      if (dur <= Duration.zero) return;

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

  bool _isZooming = false;

  void zoomReset() {
    final dur = getDuration();
    if (dur <= Duration.zero) return;
    waveform.setViewport(start: 0.0, width: 1.0);
    saveDebounced(saveMemo: false);
  }

  void _bindValueListeners() {
    _loopOnListener = () {
      if (_isZooming) return;
      saveDebounced(saveMemo: false);
    };
    waveform.loopOn.addListener(_loopOnListener!);

    _markersListener = () {
      if (_isZooming) return;
      saveDebounced(saveMemo: false);
    };
    waveform.markers.addListener(_markersListener!);
  }

  void _bindViewportListeners() {
    waveform.viewStart.addListener(() {});
    waveform.viewWidth.addListener(() {});
  }

  void onPinchStart({required double localX, required double widthPx}) {
    if (widthPx <= 0) return;

    _mode = GestureMode.pinchZooming;

    final frac = (localX / widthPx).clamp(0.0, 1.0);
    _pinchOriginFrac = frac;
    _lastScale = 1.0;
    _lastPinchAt = DateTime.now();
  }

  void onPinchUpdate(double scale) {
    if (_pinchOriginFrac == null) return;

    double delta = scale / _lastScale;

    if (delta > 1.2) delta = 1.2;
    if (delta < 0.8) delta = 0.8;

    if (delta > 0.98 && delta < 1.02) {
      _lastScale = scale;
      return;
    }

    zoomAt(cursorFrac: _pinchOriginFrac!, factor: delta);

    _lastScale = scale;
    _lastPinchAt = DateTime.now();
  }

  void onPinchEnd() {
    _mode = GestureMode.idle;
    _pinchOriginFrac = null;
    _lastScale = 1.0;
    _lastPinchAt = null;
  }
}
