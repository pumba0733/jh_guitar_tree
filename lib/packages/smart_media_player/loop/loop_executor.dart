// lib/packages/smart_media_player/loop/loop_executor.dart
//
// v3.41 — Step 3-2 Loop Execution Flow Integration (v2 revision)
// SmartMediaPlayerScreen과 100% 인터페이스/상태 호환 버전
//
// A/B 유지 + B 근접 시 재진입 + 범위 이탈 복귀 + Repeat/Remaining 정확 반영
// StartCue는 screen.dart가 책임지므로 loopExecutor는 관여하지 않음.

import 'dart:async';

class LoopExecutor {
  // ===== 외부 주입 =====
  final Duration Function() getPosition;
  final Duration Function() getDuration;

  final Future<void> Function(Duration) seek;
  final Future<void> Function() play;
  final Future<void> Function() pause;

  // ===== 콜백 =====
  final void Function(bool enabled)? onLoopStateChanged;
  final void Function(int remaining)? onLoopRemainingChanged;
  final void Function()? onExitLoop;

  LoopExecutor({
    required this.getPosition,
    required this.getDuration,
    required this.seek,
    required this.play,
    required this.pause,
    this.onLoopStateChanged,
    this.onLoopRemainingChanged,
    this.onExitLoop,
  });

  // ===== Loop 상태 =====
  Duration? loopA;
  Duration? loopB;
  bool loopOn = false;

  /// repeat=0 → 무한, screen.dart의 규칙 동일
  int repeat = 0;

  /// remaining = -1 → 무한, screen.dart 동일
  int remaining = -1;

  Timer? _tickTimer;
  bool _busy = false;

  // ============================================================
  // A. Loop On/Off
  // ============================================================
  void setLoopEnabled(bool enable) {
    loopOn = enable;

    // Step 3-7: screen과 동일
    if (!enable) {
      remaining = (repeat == 0) ? -1 : repeat;
    } else if (loopA != null && loopB != null && loopA! < loopB!) {
      remaining = (repeat == 0) ? -1 : repeat;
    } else {
      remaining = -1;
    }

    onLoopStateChanged?.call(loopOn);
    onLoopRemainingChanged?.call(remaining);
  }


  // ============================================================
  // B. Repeat
  // ============================================================
  void setRepeat(int v) {
    repeat = v.clamp(0, 200);
    if (loopOn && repeat > 0) {
      remaining = repeat;
    } else {
      remaining = -1;
    }
    onLoopRemainingChanged?.call(remaining);
  }

  // ============================================================
  // C. Loop A
  // ============================================================
  void setA(Duration d) {
    loopA = d;
    loopB = null;
    loopOn = false;

    resetRemaining();

    onLoopStateChanged?.call(false);
    onLoopRemainingChanged?.call(remaining);
  }


  // ============================================================
  // D. Loop B
  // ============================================================
  void setB(Duration d) {
    if (loopA == null) return;

    final a = loopA!;
    final dur = getDuration();

    Duration b = d;

    // screen.dart의 _normalizeLoopOrder()와 동일
    if (b <= a) {
      const two = Duration(seconds: 2);
      final corrected = ((a + two) < dur)
          ? a + two
          : (dur - const Duration(milliseconds: 1));
      b = corrected;
    }

    loopB = b;

    // 조건 충족 시 loop on
    if (loopA != null && loopB != null && loopA! < loopB!) {
      loopOn = true;

      // Step 3-7 규칙: B 설정 시 remaining 초기화(screen과 동일)
      remaining = (repeat == 0) ? -1 : repeat;

      onLoopStateChanged?.call(true);
      onLoopRemainingChanged?.call(remaining);
    }
  }

  // ============================================================
  // E. Tick Control
  // ============================================================
  void start() {
    stop();
    _tickTimer = Timer.periodic(
      const Duration(milliseconds: 60),
      (_) => _tick(),
    );
  }

  void stop() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  // ============================================================
  // F. 핵심 루프 실행부
  // ============================================================
  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;

    try {
      if (!loopOn || loopA == null || loopB == null) {
        _busy = false;
        return;
      }

      final a = loopA!;
      final b = loopB!;
      final pos = getPosition();
      final dur = getDuration();
      if (dur == Duration.zero) {
        _busy = false;
        return;
      }

      // ---------------------------------------------------------
      // 1) Loop 범위 이탈: 즉시 A로 복귀
      // ---------------------------------------------------------
      if (pos < a || pos > b) {
        await seek(a);
        await play();
        _busy = false;
        return;
      }

      // ---------------------------------------------------------
      // 2) B 근접 → 루프 1회 종료 판정
      // ---------------------------------------------------------
      const endPad = Duration(milliseconds: 30);

      if (pos >= (b - endPad)) {
        // Case: repeat > 0 -> 감소
        if (remaining > 0) {
          remaining -= 1;
          onLoopRemainingChanged?.call(remaining);
        }

        // Case: repeat 소진
        if (remaining == 0) {
          loopOn = false;
          onLoopStateChanged?.call(false);
          onLoopRemainingChanged?.call(0);
          onExitLoop?.call();
          _busy = false;
          return;
        }

        // Case: 무한 or 아직 남음 → A로 재진입
        await seek(a);
        await play();
      }
    } finally {
      _busy = false;
    }
  }

  /// Step 3-7: remaining 카운터를 screen과 통일된 규칙으로 초기화
  void resetRemaining() {
    if (repeat <= 0) {
      // 0 = infinite
      remaining = -1;
    } else {
      remaining = repeat;
    }
    onLoopRemainingChanged?.call(remaining);
  }

}
