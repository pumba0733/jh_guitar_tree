// lib/packages/smart_media_player/waveform/system/waveform_system.dart
//
// SmartMediaPlayer v3.8-FF — STEP 3 / P1
// WaveformController 정리본 (StartCue 루프 방지 포함)
//
// ✅ 책임 정리
// - FFmpeg SoT(position/duration) 기준으로 updateFromPlayer(pos, dur) 호출
// - loopA / loopB / loopOn / loopRepeat / selection / viewport / markers 상태 보관
// - onSeek / onPause / onLoopSet / onStartCueSet 콜백 슬롯 제공
// - StartCue는 Screen이 보관하고, Controller는 "표시 + notify"만 담당
//
// 🔥 중요
// - setStartCue() 는 programmatic update 전용이다.
//   → 여기서는 onStartCueSet 콜백을 절대 호출하지 않는다.
//   → 제스처에서 올라오는 StartCue는 WaveformPanel이 onStartCueSet을 직접 호출.
// - setStartCue() 안에는 재진입 가드가 있어서 Controller listener 경유 루프를 막는다.
//

import 'package:flutter/material.dart';

class WfMarker {
  final Duration time;
  String label;
  final Color? color;
  final int? repeat;

  WfMarker(this.time, this.label, {this.color, this.repeat});

  WfMarker.named({
    required Duration time,
    required String label,
    Color? color,
    int? repeat,
  }) : time = time,
       label = label,
       color = color,
       repeat = repeat;
}


class WaveformController extends ChangeNotifier {
  // === 타임라인 핵심 ===
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);

  // === Loop / Selection ===
  final ValueNotifier<Duration?> loopA = ValueNotifier<Duration?>(null);
  final ValueNotifier<Duration?> loopB = ValueNotifier<Duration?>(null);
  final ValueNotifier<bool> loopOn = ValueNotifier<bool>(false);
  final ValueNotifier<int> loopRepeat = ValueNotifier<int>(0);

  final ValueNotifier<Duration?> selectionA = ValueNotifier<Duration?>(null);
  final ValueNotifier<Duration?> selectionB = ValueNotifier<Duration?>(null);

  // === Viewport (0~1 구간) ===
  final ValueNotifier<double> viewStart = ValueNotifier<double>(0.0);
  final ValueNotifier<double> viewWidth = ValueNotifier<double>(1.0);

  // === Marker ===
  final ValueNotifier<List<WfMarker>> markers = ValueNotifier<List<WfMarker>>(
    <WfMarker>[],
  );

  // === StartCue (내부 값만 보관) ===
  Duration _startCue = Duration.zero;
  Duration get startCue => _startCue;

  // 🔥 StartCue 재진입 방지
  bool _inSetStartCue = false;

  // === Gesture / Panel 콜백 슬롯 ===
  void Function(Duration)? onSeek;
  VoidCallback? onPause;
  void Function(Duration?, Duration?)? onLoopSet;
  void Function(Duration)? onStartCueSet;

  DateTime? _lastSeekGestureAt;

  // ============================================================
  // Player → Controller SoT 동기화
  // ============================================================
  void updateFromPlayer({Duration? pos, Duration? dur}) {
    if (pos != null && pos != position.value) {
      position.value = pos;
    }
    if (dur != null && dur != duration.value) {
      duration.value = dur;
    }
  }

  void setDuration(Duration d) {
    if (d == duration.value) return;
    duration.value = d;
  }

  // ============================================================
  // Loop 설정 (A/B + on)
  // ============================================================
    // ============================================================
  // Loop 설정 (A/B + on)
  //
  // 🔥 중요:
  // - setLoop()는 "programmatic update" 전용이다.
  // - 여기서는 onLoopSet 콜백을 절대 호출하지 않는다.
  //   → onLoopSet 은 WaveformPanel(제스처) → Screen 통로로만 사용.
  // ============================================================
  void setLoop({Duration? a, Duration? b, required bool on}) {
    final changed = a != loopA.value || b != loopB.value || on != loopOn.value;

    loopA.value = a;
    loopB.value = b;
    loopOn.value = on;

    if (changed) {
      // 🔹 제스처 콜백(onLoopSet)은 여기서 호출하지 않는다.
      notifyListeners();
    }
  }


  // ============================================================
  // StartCue programmatic update
  //
  // - Screen/Sidecar/Normalize 에서 호출
  // - 제스처 콜백(onStartCueSet)은 절대 호출하지 않는다.
  // - 동일값이면 아무 것도 하지 않음.
  // - 재진입 방지 플래그로 StackOverflow 차단.
  // ============================================================
  void setStartCue(Duration value, {bool notify = true}) {
    if (_inSetStartCue) return; // 재진입 방어
    if (value == _startCue) return; // 동일값이면 무시

    _inSetStartCue = true;
    _startCue = value;

    // 🔥 여기서는 onStartCueSet 을 호출하지 않는다.
    //    → onStartCueSet 은 "제스처 → Screen" 단방향 채널로만 사용.
    if (notify) {
      notifyListeners();
    }

    _inSetStartCue = false;
  }

  // ============================================================
  // Marker / Selection / Viewport 유틸
  // ============================================================
  void setMarkers(List<WfMarker> list) {
    markers.value = List<WfMarker>.unmodifiable(list);
    notifyListeners();
  }

  void setSelection({Duration? a, Duration? b}) {
    selectionA.value = a;
    selectionB.value = b;
    notifyListeners();
  }

  void setViewport({double? start, double? width}) {
    final s = (start ?? viewStart.value).clamp(0.0, 1.0);
    final w = (width ?? viewWidth.value).clamp(0.001, 1.0);

    viewStart.value = s;
    viewWidth.value = w;
    notifyListeners();
  }

  // 제스처 쪽에서 시킹 직전에 호출 (SoT race trace용)
  void recordSeekTimestamp() {
    _lastSeekGestureAt = DateTime.now();
  }

  DateTime? get lastSeekGestureAt => _lastSeekGestureAt;

  @override
  void dispose() {
    position.dispose();
    duration.dispose();
    loopA.dispose();
    loopB.dispose();
    loopOn.dispose();
    loopRepeat.dispose();
    selectionA.dispose();
    selectionB.dispose();
    viewStart.dispose();
    viewWidth.dispose();
    markers.dispose();
    super.dispose();
  }
}
