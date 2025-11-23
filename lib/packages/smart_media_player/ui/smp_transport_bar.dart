// lib/packages/smart_media_player/ui/smp_transport_bar.dart

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
/// ================================================================
class SmpTransportBar extends StatelessWidget {
  // --- 시간/재생 상태 ---
  final Duration position;
  final Duration duration;
  final bool isPlaying;

  // --- 플레이어 제어 콜백 ---
  final VoidCallback onPlayPause;
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
          child: Text(
            '${fmt(position)} / ${fmt(duration)}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
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
          onPressed: onPlayPause,
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          iconSize: 22,
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
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
        IconButton(
          tooltip: '줌 인',
          onPressed: onZoomIn,
          icon: const Icon(Icons.zoom_in),
          iconSize: 22,
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
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

            // 🔥 LoopPanel 삽입 (TransportBar의 루프 UI 제거)
            Expanded(
              child: SmpLoopPanel(
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

            const SizedBox(width: 6),

            rightZoom,
          ],
        ),
      ),
    );
  }

}