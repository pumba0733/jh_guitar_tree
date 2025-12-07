// lib/packages/smart_media_player/models/timed_state.dart
//
// SmartMediaPlayer v3.8-FF
// - StartCue / Loop A/B / duration 의 "행동규칙 v2.1" 단일 소스
// - UI/엔진에서 쓰는 시간 상태를 순수 모델로 캡슐화
// - Screen 은 여기의 high-level 메서드만 호출해서 의사결정 결과를 받아간다.

import 'dart:core';

/// Space 키 결정용 액션 타입
enum SpaceAction { none, playFromStartCue, pause }

/// Space 키 입력에 대한 최종 의사결정 결과
class SpaceDecision {
  final SpaceAction action;
  final Duration startCue;

  const SpaceDecision({required this.action, required this.startCue});
}

/// 클릭(단일 포인트 이동)에 대한 결과
class ClickResult {
  /// 정규화 이후 StartCue
  final Duration startCue;

  /// 실제 seek 대상(정규화된 타겟)
  final Duration seekTarget;

  /// 클릭 전에 루프가 있었는지
  final bool hadLoop;

  /// 처리 과정에서 루프를 지웠는지
  final bool clearedLoop;

  const ClickResult({
    required this.startCue,
    required this.seekTarget,
    required this.hadLoop,
    required this.clearedLoop,
  });
}

/// 드래그 선택(루프 생성/실패)에 대한 결과
class DragSelectionResult {
  /// 유효한 루프를 새로 만든 경우 true
  final bool createdLoop;

  /// 루프 대신 StartCue만 이동한 경우 true
  final bool startCueOnly;

  /// 정규화 이후 StartCue
  final Duration startCue;

  /// 정규화 이후 loopA
  final Duration? loopA;

  /// 정규화 이후 loopB
  final Duration? loopB;

  const DragSelectionResult({
    required this.createdLoop,
    required this.startCueOnly,
    required this.startCue,
    required this.loopA,
    required this.loopB,
  });
}

/// 마커 점프(특정 시간으로 이동)에 대한 결과
class MarkerJumpResult {
  /// 점프 타겟 (정규화된 위치)
  final Duration target;

  /// 처리 이후 StartCue
  final Duration startCue;

  /// 이번 점프에서 StartCue 를 실제로 옮겼는지
  final bool movedStartCue;

  const MarkerJumpResult({
    required this.target,
    required this.startCue,
    required this.movedStartCue,
  });
}

class TimedState {
  /// 전체 미디어 길이 (0이면 아직 모름)
  Duration duration;

  /// StartCue (사용자 기준 시작점)
  Duration startCue;

  /// 루프 앞/뒤 지점
  Duration? loopA;
  Duration? loopB;

  bool _isNormalizing = false;
  Duration _lastNormDuration = Duration.zero;

  TimedState({
    this.duration = Duration.zero,
    this.startCue = Duration.zero,
    this.loopA,
    this.loopB,
  });

  // ===== 파생 상태 =====

  /// A/B가 존재하고 0길이가 아니고 duration 범위 안이면 true
  bool get hasValidLoopRegion {
    if (loopA == null || loopB == null) return false;
    if (loopA == loopB) return false;

    final d = duration;
    if (d > Duration.zero) {
      if (loopA! < Duration.zero || loopB! < Duration.zero) return false;
      if (loopA! > d || loopB! > d) return false;
    }
    return true;
  }

  /// "루프가 있다" = 유효한 루프 구간이 있다
  bool get hasLoop => hasValidLoopRegion;

  /// loopOn은 별도 플래그 없이 hasLoop와 동일하게 취급
  bool get loopOn => hasLoop;

  /// 앞 지점(A) (정렬 반영)
  Duration? get loopFront {
    if (!hasValidLoopRegion) return null;
    return loopA! <= loopB! ? loopA : loopB;
  }

  /// 뒤 지점(B) (정렬 반영)
  Duration? get loopBack {
    if (!hasValidLoopRegion) return null;
    return loopA! <= loopB! ? loopB : loopA;
  }

  Duration get lastNormalizedDuration => _lastNormDuration;

  // ===== 외부에서 호출할 진입점 =====

  /// duration 업데이트 후 규칙 재적용
  void updateDuration(Duration d) {
    if (d <= Duration.zero) {
      duration = d;
      return;
    }
    duration = d;
    normalize();
  }

  /// 사이드카에서 가져온 A/B/loopOn/startCue를 한 번에 주입
  ///
  /// - loopOn == false 인 경우: A/B 완전 삭제로 해석
  /// - loopOn == null 인 경우: A/B가 둘 다 있으면 루프 ON, 아니면 OFF
  void applySidecar({
    Duration? sidecarLoopA,
    Duration? sidecarLoopB,
    bool? sidecarLoopOn,
    Duration? sidecarStartCue,
  }) {
    Duration? a = sidecarLoopA;
    Duration? b = sidecarLoopB;

    final hasRegion = a != null && b != null;

    if (sidecarLoopOn is bool) {
      if (!sidecarLoopOn) {
        // 옛 사이드카에서 "루프 OFF"로 저장된 상태 → 지금은 루프 완전 삭제
        a = null;
        b = null;
      } else {
        // loopOn=true인데 A/B가 없으면 무효 → 루프 삭제
        if (!hasRegion) {
          a = null;
          b = null;
        }
      }
    } // loopOn 필드 없으면 hasRegion으로 판단

    loopA = a;
    loopB = b;
    startCue = sidecarStartCue ?? Duration.zero;

    normalize();
  }

  /// 사용자가 원하는 StartCue 후보를 넣으면,
  /// v2.1 규칙(루프 있으면 A/front, 없으면 0~duration clamp)에 맞게 정규화
  void setStartCueFromUser(Duration candidate) {
    startCue = normalizeStartCue(candidate);
  }

  /// 루프 완전 삭제 (A/B null, loopOn=false)
  void clearLoop() {
    loopA = null;
    loopB = null;
  }

  /// HOTKEY_E / 버튼 A 설정용
  ///
  /// - anchor: 현재 위치(재생 중이면 position, 정지면 StartCue 등)
  /// - B가 있고 B<=A면 B는 버린다.
  /// - StartCue는 항상 A(front)로 맞춘다.
  void setLoopA(Duration anchor) {
    final d = duration;
    var a = anchor;
    if (d > Duration.zero) a = _clamp(a, Duration.zero, d);

    Duration? b = loopB;
    if (b != null && b <= a) {
      b = null;
    }

    loopA = a;
    loopB = b;

    // StartCue는 항상 루프 앞(front)에 붙는다.
    startCue = normalizeStartCue(a, loopAOverride: a, loopBOverride: b);

    normalize();
  }

  /// HOTKEY_D / 버튼 B 설정용
  ///
  /// - A가 없으면 StartCue를 A로 간주
  /// - 앞/뒤 정렬
  /// - A==B면 루프 성립 X → A-only + StartCue=A
  void setLoopB(Duration anchor) {
    final d = duration;
    var b = anchor;
    if (d > Duration.zero) b = _clamp(b, Duration.zero, d);

    Duration? a = loopA ?? startCue;

    if (d > Duration.zero) a = _clamp(a, Duration.zero, d);

    if (b < a) {
      final tmp = a;
      a = b;
      b = tmp;
    }

    if (a == b) {
      // 0길이 → 루프 성립 X. A-only + StartCue=A
      loopA = a;
      loopB = null;
      startCue = normalizeStartCue(a, loopAOverride: a, loopBOverride: null);
      normalize();
      return;
    }

    loopA = a;
    loopB = b;

    startCue = normalizeStartCue(a, loopAOverride: a, loopBOverride: b);
    normalize();
  }

  /// 드래그 선택으로 루프를 만드는 진입점.
  ///
  /// - start/end 방향 상관 없이 앞/뒤 정렬
  /// - span < minSpan 이면 루프 만들지 않고 StartCue만 이동
  /// - span >= minSpan 이면:
  ///   • loopA = 앞
  ///   • loopB = 뒤
  ///   • StartCue = loopA(front)
  /// 반환값: true = 유효 루프 생성, false = StartCue만 이동
  bool applyLoopFromDrag({
    required Duration start,
    required Duration end,
    Duration minSpan = const Duration(milliseconds: 30),
  }) {
    final d = duration;
    if (d <= Duration.zero) {
      return false;
    }

    var a = start;
    var b = end;

    a = _clamp(a, Duration.zero, d);
    b = _clamp(b, Duration.zero, d);

    if (b < a) {
      final tmp = a;
      a = b;
      b = tmp;
    }

    final span = b - a;
    if (span <= Duration.zero || span < minSpan) {
      // 사실상 클릭으로 취급 → 루프 없이 StartCue만 이동
      setStartCueFromUser(a);
      normalize();
      return false;
    }

    loopA = a;
    loopB = b;

    startCue = normalizeStartCue(a, loopAOverride: a, loopBOverride: b);

    normalize();
    return true;
  }

  // ===== 고수준 의사결정 레이어 =====
  //
  // Screen 은 아래 메서드들만 호출해서
  //  - StartCue/Loop 상태 갱신
  //  - Space/Marker/Click 규칙 결정
  // 을 전부 여기서 위임받는다.

  /// 파형 클릭(짧은 드래그 포함)을 처리하는 고수준 메서드.
  ///
  /// 규칙:
  /// - 항상 0~duration 범위로 clamp
  /// - 루프가 있으면:
  ///   • 기존 루프 완전 삭제
  ///   • StartCue = 클릭 위치(정규화)
  /// - 루프가 없으면:
  ///   • StartCue = 클릭 위치(정규화)
  ClickResult handleClick(Duration rawTarget) {
    var target = rawTarget;

    final d = duration;
    if (d > Duration.zero) {
      target = _clamp(target, Duration.zero, d);
    } else if (target < Duration.zero) {
      target = Duration.zero;
    }

    final hadLoop = hasLoop;

    if (hadLoop) {
      clearLoop();
    }

    setStartCueFromUser(target);
    normalize();

    return ClickResult(
      startCue: startCue,
      seekTarget: target,
      hadLoop: hadLoop,
      clearedLoop: hadLoop,
    );
  }

  /// 파형 드래그 선택(루프 생성/실패)을 처리하는 고수준 메서드.
  ///
  /// - 내부적으로 [applyLoopFromDrag] 호출
  /// - createdLoop=true → 유효 루프 생성 + StartCue=A(front)
  /// - createdLoop=false → StartCue만 이동
  DragSelectionResult handleDragSelection({
    required Duration start,
    required Duration end,
    Duration minSpan = const Duration(milliseconds: 30),
  }) {
    final created = applyLoopFromDrag(start: start, end: end, minSpan: minSpan);

    return DragSelectionResult(
      createdLoop: created,
      startCueOnly: !created,
      startCue: startCue,
      loopA: loopA,
      loopB: loopB,
    );
  }

  /// 마커 점프에 대한 의사결정.
  ///
  /// - isPlaying=false (정지 상태):
  ///   • StartCue를 target으로 이동
  ///   • seek는 Screen 쪽에서 필요시 수행
  /// - isPlaying=true (재생 중):
  ///   • StartCue는 그대로 두고, target 으로 seek만 하도록 의도
  MarkerJumpResult handleMarkerJump({
    required Duration target,
    required bool isPlaying,
  }) {
    var t = target;
    final d = duration;

    if (d > Duration.zero) {
      t = _clamp(t, Duration.zero, d);
    } else if (t < Duration.zero) {
      t = Duration.zero;
    }

    bool moved = false;

    if (!isPlaying) {
      setStartCueFromUser(t);
      moved = true;
    }

    normalize();

    return MarkerJumpResult(
      target: t,
      startCue: startCue,
      movedStartCue: moved,
    );
  }

  /// Space 키에 대한 최종 행동 결정.
  ///
  /// - isPlaying=true  → 일시정지
  /// - isPlaying=false → StartCue에서 재생
  ///
  /// Track-end / LoopExit 등은 Executor/Engine 쪽에서 별도 처리.
  SpaceDecision decideSpace({
    required bool isPlaying,
    required Duration position,
  }) {
    // position 을 직접 쓰진 않지만, 필요 시 확장 가능하므로 인자로 받는다.
    // StartCue/Loop 는 normalize 로 항상 일관된 상태 유지.
    normalize();

    if (isPlaying) {
      return SpaceDecision(action: SpaceAction.pause, startCue: startCue);
    }

    // 정지 상태 → StartCue 기준 재생
    return SpaceDecision(
      action: SpaceAction.playFromStartCue,
      startCue: startCue,
    );
  }

  // ===== 핵심 정규화 =====

  /// v2.1 전체 규칙을 한 번에 적용.
  ///
  /// - A/B를 duration에 맞게 clamp + 정렬
  /// - 유효하지 않은 루프(반쪽/0길이)는 모두 제거
  /// - StartCue:
  ///   • 루프 없으면: 0~duration clamp
  ///   • 루프 있으면: 항상 A(front)에 고정
  void normalize() {
    if (_isNormalizing) {
      // 로그는 Screen 쪽에서 찍기
      return;
    }

    _isNormalizing = true;
    try {
      final d = duration;

      Duration? a = loopA;
      Duration? b = loopB;
      Duration sc = startCue;

      // 1) 기본 clamp
      if (d > Duration.zero) {
        if (a != null) a = _clamp(a, Duration.zero, d);
        if (b != null) b = _clamp(b, Duration.zero, d);
        sc = _clamp(sc, Duration.zero, d);
      } else {
        if (a != null && a < Duration.zero) a = Duration.zero;
        if (b != null && b < Duration.zero) b = Duration.zero;
        if (sc < Duration.zero) sc = Duration.zero;
      }

      // 2) 루프 유효성 정리
      bool hasLoopRegion = false;
      if (a != null && b != null && a != b) {
        if (a > b) {
          final tmp = a;
          a = b;
          b = tmp;
        }
        hasLoopRegion = true;
      } else {
        a = null;
        b = null;
        hasLoopRegion = false;
      }

      // 3) StartCue 정규화
      sc = normalizeStartCue(sc, loopAOverride: a, loopBOverride: b);

      loopA = a;
      loopB = b;
      startCue = sc;
      _lastNormDuration = d;

      // 안정성 보장: 유효 루프가 있으면 hasLoop == true여야 한다.
      assert(
        !hasLoopRegion || hasLoop,
        'Loop region exists but hasLoop=false in TimedState',
      );
    } finally {
      _isNormalizing = false;
    }
  }

  /// StartCue만 별도 정규화가 필요할 때 사용.
  ///
  /// - 루프 없으면: 0 ~ duration clamp
  /// - 루프 있으면: 항상 A(front)에 강제 고정
  Duration normalizeStartCue(
    Duration candidate, {
    Duration? loopAOverride,
    Duration? loopBOverride,
  }) {
    final d = duration;
    Duration sc = candidate;

    // 기본 clamp
    if (d > Duration.zero) {
      sc = _clamp(sc, Duration.zero, d);
    } else if (sc < Duration.zero) {
      sc = Duration.zero;
    }

    // 루프가 있으면 StartCue는 항상 A(front)
    final a = loopAOverride ?? loopA;
    final b = loopBOverride ?? loopB;

    if (a != null && b != null && a != b) {
      final front = a <= b ? a : b;
      if (d > Duration.zero) {
        sc = _clamp(front, Duration.zero, d);
      } else {
        sc = front;
      }
    }

    return sc;
  }

  // ===== 내부 유틸 =====

  Duration _clamp(Duration value, Duration min, Duration max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}
