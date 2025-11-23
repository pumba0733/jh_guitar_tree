// lib/packages/smart_media_player/ui/smp_loop_panel.dart

import 'package:flutter/material.dart';

// AppSection, AppMiniButton
import '../../../ui/components/app_controls.dart';

// HoldIconButton, RemainingPill
import 'smp_transport_bar.dart';

// 공용 preset item
import '../../../ui/components/loop_preset_item.dart';

/// ===================================================================
///  UI-Only Loop Panel (TransportBar의 Loop 영역만 독립화)
/// ===================================================================
class SmpLoopPanel extends StatelessWidget {
  final Duration? loopA;
  final Duration? loopB;
  final bool loopEnabled;

  final int loopRepeat;
  final int loopRemaining;

  final VoidCallback onLoopASet;
  final VoidCallback onLoopBSet;

  final ValueChanged<bool> onLoopToggle;

  final VoidCallback onLoopRepeatMinus1;
  final VoidCallback onLoopRepeatPlus1;
  final VoidCallback onLoopRepeatLongMinus5;
  final VoidCallback onLoopRepeatLongPlus5;
  final VoidCallback onLoopRepeatPrompt;

  final List<LoopPresetItem> loopPresets;
  final ValueChanged<int> onLoopPresetSelected;

  /// fmt(Duration) 외부 주입 방식
  final String Function(Duration) fmt;

  const SmpLoopPanel({
    super.key,
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
    required this.loopPresets,
    required this.onLoopPresetSelected,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const w4 = SizedBox(width: 4);
    const w6 = SizedBox(width: 6);

    return AppSection(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            // ---- Loop A/B ----
            AppMiniButton(
              compact: true,
              icon: Icons.playlist_add,
              label: loopA == null ? '루프 시작' : '루프 시작 ${fmt(loopA!)}',
              onPressed: onLoopASet,
            ),
            w6,
            AppMiniButton(
              compact: true,
              icon: Icons.playlist_add_check,
              label: loopB == null ? '루프 끝' : '루프 끝 ${fmt(loopB!)}',
              onPressed: onLoopBSet,
            ),

            const SizedBox(width: 10),

            // ---- Loop Switch ----
            Row(
              children: [
                Text('반복', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 6),
                Switch.adaptive(
                  value: loopEnabled,
                  onChanged: onLoopToggle,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),

            const SizedBox(width: 10),

            // ---- repeat -/+ ----
            HoldIconButton(
              icon: Icons.remove,
              onDown: onLoopRepeatMinus1,
              onUp: onLoopRepeatLongMinus5, // ← 롱프레스 복원
            ),
            w4,
            InkWell(
              onTap: onLoopRepeatPrompt,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  loopRepeat == 0 ? '∞' : '$loopRepeat',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            w4,
            HoldIconButton(
              icon: Icons.add,
              onDown: onLoopRepeatPlus1,
              onUp: onLoopRepeatLongPlus5, // ← 롱프레스 복원
            ),

            w6,

            // ---- Preset popup ----
            PopupMenuButton<int>(
              tooltip: '반복 프리셋',
              itemBuilder: (ctx) => [
                for (final p in loopPresets)
                  PopupMenuItem<int>(value: p.repeats, child: Text(p.label)),
                const PopupMenuDivider(),
                const PopupMenuItem<int>(value: 0, child: Text('∞ (무한반복)')),
                const PopupMenuItem<int>(value: -999, child: Text('직접 입력…')),
              ],
              onSelected: onLoopPresetSelected,
              child: const Icon(Icons.more_horiz, size: 20),
            ),

            const SizedBox(width: 12),

            // ---- Remaining pill ----
            RemainingPill(
              loopEnabled: loopEnabled,
              loopRepeat: loopRepeat,
              loopRemaining: loopRemaining,
            ),
          ],
        ),
      ),
    );
  }
}
