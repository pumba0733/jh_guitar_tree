// lib/packages/smart_media_player/waveform/system/waveform_system.dart
//
// SmartMediaPlayer v3.8-FF — STEP 3 / P1
// WaveformController 1차 정렬본
//
// ✅ 책임 정리
// - AudioChain / SoundTouchAudioChain 의존성 완전 제거
// - 외부(EngineApi.position/duration 스트림 등)가 FFmpeg SoT 기준으로
//   updateFromPlayer(pos, dur)를 호출하는 구조로 사용
// - 이 레벨에서는 StartCue / Loop / Seek를 "값 보관 + 콜백 전달"만 하고,
//   재생 규칙(Loop 진입/탈출, Space, FF/FR)은 전부 EngineApi / Screen 쪽 책임.
//
// ✅ 타임라인 / 규칙
// - FF/FR/파형 드래그 = 항상 0 ~ duration 자유 이동
//   → 여기서는 clamp만 duration 기준으로 처리
// - StartCue / Loop 값은 여기서 “벽”으로 쓰이지 않는다.
// - SoT(EngineApi.position)는 updateFromPlayer로만 들어오고,
//   recordSeekTimestamp() + _blockWindow로 seek 직후 낡은 position을 무시한다.
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

  /// Start Cue 설정 시 호출.
  void Function(Duration t)? onStartCueSet;

  /// 드래그 끝 등으로 loop 구간이 확정될 때 호출.
  void Function(Duration a, Duration b)? onLoopSet;

  /// 필요 시 외부에서 일시정지를 걸고 싶을 때 사용할 수 있는 선택적 hook.
  void Function()? onPause;

  void Function()? onMarkersChanged;

  // ===============================================================
  // INTERNAL HELPERS
  // ===============================================================

  /// 0ms ~ duration.value 범위로 clamp.
  ///
  /// - duration이 아직 0이면 상한은 강제하지 않고, 0ms 이하만 막는다.
  Duration _clampToDuration(Duration t) {
    var result = t;
    if (result.isNegative) {
      result = Duration.zero;
    }
    final d = duration.value;
    if (d > Duration.zero && result > d) {
      result = d;
    }
    return result;
  }

  /// Controller 내부에서 “사용자 제스처 기반 seek를 트리거”할 때
  /// 이 메서드를 먼저 호출해 두면,
  /// 이후 짧은 시간(_blockWindow 동안) 동안 엔진 position 스트림에서 오는
  /// 오래된 값들은 무시된다.
  void recordSeekTimestamp() {
    _lastSeekAt = DateTime.now();
  }

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
  // SEEK / DRAG ENTRYPOINTS (UI → ENGINE)
  // ===============================================================

  /// FF/FR/파형 드래그 등 “타임라인 자유 이동”용 통합 엔트리 포인트.
  ///
  /// - [target]은 항상 0 ~ duration 범위로 clamp
  /// - 내부에서 recordSeekTimestamp()를 호출해 seek race 방지
  /// - 필요 시 [pauseBeforeSeek]로 엔진 측 일시정지를 먼저 트리거
  /// - position.value를 즉시 갱신해서 UI를 빠르게 따라가게 만든다.
  void requestSeek(Duration target, {bool pauseBeforeSeek = false}) {
    final clamped = _clampToDuration(target);

    recordSeekTimestamp();

    if (pauseBeforeSeek) {
      onPause?.call();
    }

    // UI를 먼저 최신 위치로 갱신
    position.value = clamped;

    // 엔진 쪽으로 실제 seek 전달
    onSeek?.call(clamped);
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

    _vpLog('viewport set: start=$s width=$w');
  }

  // ===============================================================
  // LOOP / START CUE / SELECTION / MARKERS
  // ===============================================================

  /// Loop 값 세팅 (엔진 규칙은 건드리지 않음 / 여기서는 값 보관만).
  void setLoop({Duration? a, Duration? b, bool? on}) {
    if (a != null) {
      loopA.value = _clampToDuration(a);
    }
    if (b != null) {
      loopB.value = _clampToDuration(b);
    }
    if (on != null) {
      loopOn.value = on;
    }
  }

  /// Selection은 순수 시각적 개념.
  /// - loop와는 별개
  /// - StartCue/Loop의 “벽” 역할을 하지 않는다.
  void setSelection({Duration? a, Duration? b, bool clear = false}) {
    if (clear) {
      selectionA.value = null;
      selectionB.value = null;
      return;
    }

    if (a != null) {
      selectionA.value = _clampToDuration(a);
    }
    if (b != null) {
      selectionB.value = _clampToDuration(b);
    }
  }

  void clearSelection() {
    selectionA.value = null;
    selectionB.value = null;
  }

  void setStartCue(Duration t) {
    final clamped = _clampToDuration(t);
    startCue.value = clamped;
    onStartCueSet?.call(clamped);
  }

  void setMarkers(List<WfMarker> list) {
    // Marker time도 0~duration 범위로 정리
    final d = duration.value;
    final normalized = list.map((m) {
      final clampedTime = (d > Duration.zero)
          ? _clampToDuration(m.time)
          : (m.time.isNegative ? Duration.zero : m.time);
      if (clampedTime == m.time) return m;
      return WfMarker.named(
        time: clampedTime,
        label: m.label,
        color: m.color,
        repeat: m.repeat,
      );
    }).toList();

    markers.value = normalized;
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
