// lib/packages/smart_media_player/ui/smp_transport_bar.dart
//
// P3 기준 역할 정리:
// - 이 위젯은 "순수 UI 전용" Transport Bar.
// - 재생/일시정지/FF/FR/Loop/UI 제어는 모두 콜백으로만 외부에 위임한다.
// - 실제 엔진 규칙(EngineApi.spaceBehavior / FFRW / Loop 규칙 통합)은
//   smart_media_player_screen.dart 쪽에서 이 콜백을 통해 연결한다.

import 'package:flutter/material.dart';
import '../../../ui/components/app_controls.dart';
import '../../../ui/components/loop_preset_item.dart';
import 'smp_loop_panel.dart';

/// ================================================================
/// Public 승격: 기존 screen.dart 내부 private 위젯
/// ================================================================
class HoldIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onDown;
  final VoidCallback onUp;

  const HoldIconButton({
    super.key,
    required this.icon,
    required this.onDown,
    required this.onUp,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => onDown(),
      onPointerUp: (_) => onUp(),
      onPointerCancel: (_) => onUp(),
      child: IconButton(
        onPressed: () {},
        icon: Icon(icon),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 32),
        visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
        splashRadius: 18,
      ),
    );
  }
}

/// 잔여 반복 Pill
class RemainingPill extends StatelessWidget {
  final bool loopEnabled;
  final int loopRepeat;
  final int loopRemaining;

  const RemainingPill({
    super.key,
    required this.loopEnabled,
    required this.loopRepeat,
    required this.loopRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final txt = !loopEnabled
        ? '잔여: -'
        : (loopRepeat == 0
              ? '잔여: ∞'
              : '잔여: ${loopRemaining < 0 ? loopRepeat : loopRemaining}회');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
      ),
      child: Text(txt, style: theme.textTheme.bodySmall),
    );
  }
}

/// ================================================================
/// Transport Bar 본체 (UI-only)
/// - onPlayPause  : P3에서 EngineApi.spaceBehavior(...)에 연결될 예정
/// - onHold* 콜백 : EngineApi.ffrw.startForward/startReverse에 연결될 예정
/// ================================================================
class SmpTransportBar extends StatelessWidget {
  // --- 시간/재생 상태 ---
  final Duration position;
  final Duration duration;
  final bool isPlaying;

  // --- 플레이어 제어 콜백 ---
  /// P3 통합 규칙에서 "Space 행동"에 대응되는 콜백.
  /// 실제 구현은 screen 쪽에서 EngineApi.spaceBehavior(...)로 연결한다.
  final VoidCallback onPlayPause;

  /// P3 통합 규칙에서 FF/FR 진입점에 대응되는 콜백들.
  /// 실제 구현은 screen 쪽에서 EngineApi.ffrw.start*/stop*에 연결한다.
  final VoidCallback onHoldReverseStart;
  final VoidCallback onHoldReverseEnd;
  final VoidCallback onHoldForwardStart;
  final VoidCallback onHoldForwardEnd;

  // --- Loop 상태 ---
  final Duration? loopA;
  final Duration? loopB;
  final bool loopEnabled;
  final int loopRepeat;
  final int loopRemaining;

  // --- Loop 동작 콜백 ---
  final VoidCallback onLoopASet;
  final VoidCallback onLoopBSet;
  final ValueChanged<bool> onLoopToggle;
  final VoidCallback onLoopRepeatMinus1;
  final VoidCallback onLoopRepeatPlus1;
  final VoidCallback onLoopRepeatLongMinus5;
  final VoidCallback onLoopRepeatLongPlus5;
  final VoidCallback onLoopRepeatPrompt;
  final ValueChanged<int> onLoopPresetSelected;

  // --- Zoom ---
  final VoidCallback onZoomOut;
  final VoidCallback onZoomReset;
  final VoidCallback onZoomIn;

  // --- Presets for Popup ---
  final List<LoopPresetItem> loopPresets;

  // --- fmt 함수 외부 주입 방식 ---
  final String Function(Duration) fmt;

  const SmpTransportBar({
    super.key,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onHoldReverseStart,
    required this.onHoldReverseEnd,
    required this.onHoldForwardStart,
    required this.onHoldForwardEnd,
    required this.loopA,
    required this.loopB,
    required this.loopEnabled,
    required this.loopRepeat,
    required this.loopRemaining,
    required this.onLoopASet,
    required this.onLoopBSet,
    required this.onLoopToggle,
    required this.onLoopRepeatMinus1,
    required this.onLoopRepeatPlus1,
    required this.onLoopRepeatLongMinus5,
    required this.onLoopRepeatLongPlus5,
    required this.onLoopRepeatPrompt,
    required this.onLoopPresetSelected,
    required this.onZoomOut,
    required this.onZoomReset,
    required this.onZoomIn,
    required this.loopPresets,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const w4 = SizedBox(width: 4);
    const w6 = SizedBox(width: 6);

    // --------------------- LEFT CLUSTER ----------------------
    final left = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.28),
            ),
          ),
          child: SizedBox(
            width: 130, // 고정폭 → 흔들림 제거
            child: _TimelineText(
              position: position,
              duration: duration,
              fmt: fmt,
            ),
          ),
        ),
        w6,
        HoldIconButton(
          icon: Icons.fast_rewind,
          onDown: onHoldReverseStart,
          onUp: onHoldReverseEnd,
        ),
        w4,
        IconButton(
          tooltip: isPlaying ? '일시정지' : '재생',
          onPressed: () {
            onPlayPause();
          },
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 0), // 즉시 전환
            switchInCurve: Curves.linear,
            switchOutCurve: Curves.linear,
            child: Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
              key: ValueKey(isPlaying),
            ),
          ),
        ),
        w4,
        HoldIconButton(
          icon: Icons.fast_forward,
          onDown: onHoldForwardStart,
          onUp: onHoldForwardEnd,
        ),
      ],
    );

    // --------------------- RIGHT CLUSTER ----------------------
    final rightZoom = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '줌 아웃',
          onPressed: onZoomOut,
          icon: const Icon(Icons.zoom_out),
          iconSize: 22,
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '줌 리셋',
          onPressed: onZoomReset,
          icon: const Icon(Icons.center_focus_strong),
          iconSize: 22,
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 32,
          height: 32,
          child: IconButton(
            tooltip: '줌 인',
            onPressed: onZoomIn,
            icon: const Icon(Icons.zoom_in, size: 22),
            padding: EdgeInsets.zero,
            splashRadius: 18,
          ),
        ),
      ],
    );

    // --------------------- MAIN BAR ----------------------
    return AppSection(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220),
              child: left,
            ),
            const SizedBox(width: 6),
            // LoopPanel (Loop UI는 별도 패널로 위임, TransportBar는 순수 View)
            Expanded(
              child: RepaintBoundary(
                child: SmpLoopPanel(
                  key: ValueKey('$loopEnabled-$loopRepeat-$loopRemaining'),
                  loopA: loopA,
                  loopB: loopB,
                  loopEnabled: loopEnabled,
                  loopRepeat: loopRepeat,
                  loopRemaining: loopRemaining,
                  onLoopASet: onLoopASet,
                  onLoopBSet: onLoopBSet,
                  onLoopToggle: onLoopToggle,
                  onLoopRepeatMinus1: onLoopRepeatMinus1,
                  onLoopRepeatPlus1: onLoopRepeatPlus1,
                  onLoopRepeatLongMinus5: onLoopRepeatLongMinus5,
                  onLoopRepeatLongPlus5: onLoopRepeatLongPlus5,
                  onLoopRepeatPrompt: onLoopRepeatPrompt,
                  loopPresets: loopPresets,
                  onLoopPresetSelected: onLoopPresetSelected,
                  fmt: fmt,
                ),
              ),
            ),
            const SizedBox(width: 6),
            rightZoom,
          ],
        ),
      ),
    );
  }
}

class _TimelineText extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final String Function(Duration) fmt;

  const _TimelineText({
    required this.position,
    required this.duration,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = '${fmt(position)} / ${fmt(duration)}';

    return Text(
      text,
      textAlign: TextAlign.center,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}
