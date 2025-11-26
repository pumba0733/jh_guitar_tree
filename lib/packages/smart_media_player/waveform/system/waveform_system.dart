// lib/packages/smart_media_player/waveform/system/waveform_system.dart
//
// SmartMediaPlayer v3.8-FF — STEP 7 준비용 WaveformController
// - AudioChain / SoundTouchAudioChain 의존성 완전 제거
// - 외부(EngineApi.position/duration 스트림 등)가 FFmpeg SoT 기준으로
//   updateFromPlayer(pos, dur)를 호출하는 구조로 사용
//

import 'package:flutter/material.dart';

class WfMarker {
  final Duration time;
  final String? label;
  final Color? color;
  final bool repeat;

  const WfMarker(this.time, [this.label, this.color, this.repeat = false]);

  const WfMarker.named({
    required this.time,
    this.label,
    this.color,
    this.repeat = false,
  });
}

class WaveformController {
  // ===== Timeline =====
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  // ===== Internal timing guards (seek 직후 엔진 position 스트림 무시용) =====
  DateTime? _lastSeekAt;
  final Duration _blockWindow = const Duration(milliseconds: 120);

  // ===== Viewport (0~1 frac) =====
  final ValueNotifier<double> viewStart = ValueNotifier(0.0);
  final ValueNotifier<double> viewWidth = ValueNotifier(1.0);

  // ===== Loop (player state) =====
  final ValueNotifier<Duration?> loopA = ValueNotifier<Duration?>(null);
  final ValueNotifier<Duration?> loopB = ValueNotifier<Duration?>(null);
  final ValueNotifier<bool> loopOn = ValueNotifier<bool>(false);
  final ValueNotifier<int> loopRepeat = ValueNotifier<int>(0);

  // ===== Selection (visual-only) =====
  final ValueNotifier<Duration?> selectionA = ValueNotifier<Duration?>(null);
  final ValueNotifier<Duration?> selectionB = ValueNotifier<Duration?>(null);

  // ===== Markers =====
  final ValueNotifier<List<WfMarker>> markers = ValueNotifier<List<WfMarker>>(
    <WfMarker>[],
  );

  // ===== Start Cue =====
  final ValueNotifier<Duration?> startCue = ValueNotifier<Duration?>(null);

  // ===== Bridge callbacks (Panel -> Screen/Engine) =====
  /// 클릭/스크럽 등으로 발생한 seek 요청.
  /// 외부에서 EngineApi.seekUnified(...) 등을 호출하도록 연결.
  void Function(Duration t)? onSeek;

  /// Controller 내부에서 “사용자 제스처 기반 seek를 트리거”할 때
  /// 이 메서드를 먼저 호출해 두면,
  /// 이후 짧은 시간(_blockWindow 동안) 동안 엔진 position 스트림에서 오는
  /// 오래된 값들은 무시된다.
  void recordSeekTimestamp() {
    _lastSeekAt = DateTime.now();
  }

  /// 드래그 끝 등으로 loop 구간이 확정될 때 호출.
  void Function(Duration a, Duration b)? onLoopSet;

  /// Start Cue 설정 시 호출.
  void Function(Duration t)? onStartCueSet;

  /// 필요 시 외부에서 일시정지를 걸고 싶을 때 사용할 수 있는 선택적 hook.
  void Function()? onPause;

  // ===============================================================
  // ENGINE (FFmpeg SoT) -> CONTROLLER 동기화
  // ===============================================================

  /// EngineApi.position / EngineApi.duration(FFmpeg SoT)을 기준으로
  /// 주기적으로 호출되는 업데이트 엔트리 포인트.
  ///
  /// - [dur]이 주어지면 duration ValueNotifier를 갱신
  /// - [pos]가 주어지면, 최근 recordSeekTimestamp() 이후
  ///   _blockWindow 안에 들어온 값은 무시 (seek race 방지)
  void updateFromPlayer({Duration? pos, Duration? dur}) {
    // ----- duration 안정화 -----
    if (dur != null) {
      if (duration.value == Duration.zero && dur > Duration.zero) {
        duration.value = dur;
      } else if (duration.value > Duration.zero && dur > Duration.zero) {
        duration.value = dur;
      }
    }

    // ----- position seek-race 방지 -----
    if (pos != null) {
      final now = DateTime.now();
      if (_lastSeekAt != null && now.difference(_lastSeekAt!) < _blockWindow) {
        // seek 직후 짧은 시간 동안의 오래된 position 값은 무시
        return;
      }
      position.value = pos;
    }
  }

  // ===============================================================
  // DRIFT-FREE VIEWPORT — Step 7-2
  // ===============================================================
  void setViewport({required double start, required double width}) {
    double _norm(double v) => double.parse(v.toStringAsFixed(8));

    double s = _norm(start.clamp(0.0, 1.0));
    double w = _norm(width.clamp(0.01, 1.0));

    if (s + w > 1.0) {
      s = _norm(1.0 - w);
      if (s < 0.0) s = 0.0;
    }

    viewStart.value = s;
    viewWidth.value = w;
  }

  // ===============================================================
  // LOOP / START CUE / MARKERS
  // ===============================================================

  void setLoop({Duration? a, Duration? b, bool? on}) {
    if (a != null) loopA.value = a;
    if (b != null) loopB.value = b;
    if (on != null) loopOn.value = on;

    // selection은 시각적 개념으로만 유지 (자동 해제 없음)
  }

  void setStartCue(Duration t) {
    startCue.value = t;
    onStartCueSet?.call(t);
  }

  void Function()? onMarkersChanged;

  void setMarkers(List<WfMarker> list) {
    markers.value = list;
    onMarkersChanged?.call();
  }

  // ===============================================================
  // LIFECYCLE
  // ===============================================================

  void dispose() {
    // 현재는 외부 스트림에 직접 subscribe 하지 않는 순수 컨트롤러.
    // 이후 EngineApi.position 스트림 등에 직접 바인딩하는 기능을
    // 추가한다면, 여기에서 StreamSubscription 정리 로직을 넣으면 된다.
  }

  // ===============================================================
  // DEBUG (optional)
  // ===============================================================

  bool debugTrackViewport = false;
  DateTime? _lastVpLogAt;

  void _vpLog(String s) {
    if (!debugTrackViewport) return;
    final now = DateTime.now();
    if (_lastVpLogAt == null ||
        now.difference(_lastVpLogAt!) > const Duration(milliseconds: 300)) {
      // ignore: avoid_print
      print('[WaveformController] $s');
      _lastVpLogAt = now;
    }
  }

  // 외부에서 duration을 강제로 세팅하고 싶을 때 사용할 수 있는 헬퍼
  void setDuration(Duration d) {
    duration.value = d;
  }
}
