// lib/packages/smart_media_player/waveform/system/waveform_system.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 마커 모델
class WfMarker {
  Duration t;
  String label;
  Color? color;
  WfMarker(this.t, this.label, {this.color});
  Map<String, dynamic> toJson() => {
    't': t.inMilliseconds,
    'label': label,
    if (color != null)
      'color':
          '#${color!.value.toRadixString(16).padLeft(8, '0').toUpperCase()}',
  };
}

/// 파형 영역 전용 컨트롤러 — 화면 밖(플레이어 등)에서 구독/지정
class WaveformController {
  // 타임라인
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  // 뷰포트(줌/팬)
  final ValueNotifier<double> viewStart = ValueNotifier(0.0); // 0..1
  final ValueNotifier<double> viewWidth = ValueNotifier(1.0); // 0..1

  // 루프/시작점
  final ValueNotifier<Duration?> loopA = ValueNotifier(null);
  final ValueNotifier<Duration?> loopB = ValueNotifier(null);
  final ValueNotifier<bool> loopOn = ValueNotifier(false);
  final ValueNotifier<int> loopRepeat = ValueNotifier(0); // 0 = ∞
  final ValueNotifier<Duration> startCue = ValueNotifier(Duration.zero);

  // 선택(드래그)
  final ValueNotifier<Duration?> selA = ValueNotifier(null);
  final ValueNotifier<Duration?> selB = ValueNotifier(null);

  // 마커
  final ValueNotifier<List<WfMarker>> markers = ValueNotifier(<WfMarker>[]);

  // ==== 콜백 (호출자 주입) ====
  Future<void> Function(Duration d)? onSeek;
  void Function(Duration d)? onStartCueChanged;
  void Function(Duration? a, Duration? b, bool on)? onLoopChanged;
  void Function(List<WfMarker> m)? onMarkersChanged;
  void Function(double start, double width)? onViewportChanged;

  // ==== 유틸 ====
  void updateFromPlayer({required Duration pos, required Duration dur}) {
    if (dur != duration.value) duration.value = dur;
    if (pos != position.value) position.value = pos;
  }

  void setViewport({double? start, double? width}) {
    if (start != null) viewStart.value = start.clamp(0.0, 1.0);
    if (width != null) viewWidth.value = width.clamp(0.0, 1.0);
    onViewportChanged?.call(viewStart.value, viewWidth.value);
  }

  void setLoop({Duration? a, Duration? b, bool? on, int? repeat}) {
    if (a != null) loopA.value = a;
    if (b != null) loopB.value = b;
    if (on != null) loopOn.value = on;
    if (repeat != null) loopRepeat.value = repeat.clamp(0, 200);
    onLoopChanged?.call(loopA.value, loopB.value, loopOn.value);
  }

  void setStartCue(Duration d) {
    startCue.value = d;
    onStartCueChanged?.call(d);
  }

  void setMarkers(List<WfMarker> next) {
    markers.value = List<WfMarker>.from(next);
    onMarkersChanged?.call(markers.value);
  }

  /// 전체 보기
  void resetViewport() => setViewport(start: 0.0, width: 1.0);

  void dispose() {
    duration.dispose();
    position.dispose();
    viewStart.dispose();
    viewWidth.dispose();
    loopA.dispose();
    loopB.dispose();
    loopOn.dispose();
    loopRepeat.dispose();
    startCue.dispose();
    selA.dispose();
    selB.dispose();
    markers.dispose();
  }
}
