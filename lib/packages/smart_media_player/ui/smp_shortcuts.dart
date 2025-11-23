// lib/packages/smart_media_player/ui/smp_shortcuts.dart
// v3.41 Step 2-5 — Shortcuts/Actions/Intents 완전 분리본

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ===============================================================
///  PUBLIC API: SmartMediaPlayerShortcuts
///  - 화면에서 제공하는 기능 콜백들을 받아
///    Shortcuts + Actions + FocusNode 구조를 만들어 준다.
/// ===============================================================
class SmpsShortcuts extends StatelessWidget {
  final FocusNode focusNode;
  final Widget child;
  final VoidCallback onPlayFromStartOrPause;

  final VoidCallback onToggleLoop;
  final VoidCallback onLoopASet;
  final VoidCallback onLoopBSet;

  final VoidCallback onMarkerAdd;
  final void Function(int index1based) onMarkerJump;
  final VoidCallback onMarkerPrev;
  final VoidCallback onMarkerNext;

  final void Function(bool zoomIn) onZoom;
  final VoidCallback onZoomReset;

  final void Function(int semis) onPitchNudge;
  final void Function(double speed) onSpeedPreset;
  final void Function(int deltaPercent) onSpeedNudge;

  final KeyEventResult Function(FocusNode node, KeyEvent evt)? onKeyEvent;

  const SmpsShortcuts({
    super.key,
    required this.focusNode,
    required this.child,
    required this.onPlayFromStartOrPause,
    required this.onToggleLoop,
    required this.onLoopASet,
    required this.onLoopBSet,
    required this.onMarkerAdd,
    required this.onMarkerJump,
    required this.onMarkerPrev,
    required this.onMarkerNext,
    required this.onZoom,
    required this.onZoomReset,
    required this.onPitchNudge,
    required this.onSpeedPreset,
    required this.onSpeedNudge,
    this.onKeyEvent,
  });

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: _buildShortcutsMap(),
      child: Actions(
        actions: _buildActionsMap(),
        child: Focus(
          focusNode: focusNode,
          autofocus: true,
          skipTraversal: true,
          canRequestFocus: true,
          onKeyEvent: onKeyEvent,
          child: child, // wrapper
        ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // Shortcuts
  // ---------------------------------------------------------------
  Map<ShortcutActivator, Intent> _buildShortcutsMap() {
    return {
      // Space
      LogicalKeySet(LogicalKeyboardKey.space):
          const _PlayFromStartOrPauseIntent(),

      // Loop
      LogicalKeySet(LogicalKeyboardKey.keyL): const _ToggleLoopIntent(),
      LogicalKeySet(LogicalKeyboardKey.keyE): const _SetLoopIntent(true),
      LogicalKeySet(LogicalKeyboardKey.keyD): const _SetLoopIntent(false),

      // Markers
      LogicalKeySet(LogicalKeyboardKey.keyM): const _AddMarkerIntent(),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit1):
          const _JumpMarkerIntent(1),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit2):
          const _JumpMarkerIntent(2),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit3):
          const _JumpMarkerIntent(3),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit4):
          const _JumpMarkerIntent(4),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit5):
          const _JumpMarkerIntent(5),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit6):
          const _JumpMarkerIntent(6),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit7):
          const _JumpMarkerIntent(7),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit8):
          const _JumpMarkerIntent(8),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.digit9):
          const _JumpMarkerIntent(9),

      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowLeft):
          const _PrevNextMarkerIntent(false),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowRight):
          const _PrevNextMarkerIntent(true),

      // Pitch
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowUp):
          const _PitchUpIntent(),
      LogicalKeySet(LogicalKeyboardKey.alt, LogicalKeyboardKey.arrowDown):
          const _PitchDownIntent(),

      // Speed Presets
      LogicalKeySet(LogicalKeyboardKey.digit5): const _SpeedPresetIntent(0.5),
      LogicalKeySet(LogicalKeyboardKey.digit6): const _SpeedPresetIntent(0.6),
      LogicalKeySet(LogicalKeyboardKey.digit7): const _SpeedPresetIntent(0.7),
      LogicalKeySet(LogicalKeyboardKey.digit8): const _SpeedPresetIntent(0.8),
      LogicalKeySet(LogicalKeyboardKey.digit9): const _SpeedPresetIntent(0.9),
      LogicalKeySet(LogicalKeyboardKey.digit0): const _SpeedPresetIntent(1.0),

      // Speed nudge
      LogicalKeySet(LogicalKeyboardKey.bracketLeft): const _TempoNudgeIntent(
        -5,
      ),
      LogicalKeySet(LogicalKeyboardKey.bracketRight): const _TempoNudgeIntent(
        5,
      ),

      // Zoom
      const SingleActivator(LogicalKeyboardKey.equal, alt: true): _ZoomIntent(
        true,
      ),
      const SingleActivator(LogicalKeyboardKey.minus, alt: true): _ZoomIntent(
        false,
      ),
      const SingleActivator(LogicalKeyboardKey.digit0, alt: true):
          _ZoomResetIntent(),
      const SingleActivator(LogicalKeyboardKey.comma, alt: true): _ZoomIntent(
        false,
      ),
      const SingleActivator(LogicalKeyboardKey.period, alt: true): _ZoomIntent(
        true,
      ),
    };
  }

  // ---------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------
  Map<Type, Action<Intent>> _buildActionsMap() {
    return {
      _PlayFromStartOrPauseIntent: CallbackAction<_PlayFromStartOrPauseIntent>(
        onInvoke: (_) {
          onPlayFromStartOrPause();
          return null;
        },
      ),

      _ToggleLoopIntent: CallbackAction<_ToggleLoopIntent>(
        onInvoke: (_) {
          onToggleLoop();
          return null;
        },
      ),

      _SetLoopIntent: CallbackAction<_SetLoopIntent>(
        onInvoke: (i) {
          if (i.isA) {
            onLoopASet();
          } else {
            onLoopBSet();
          }
          return null;
        },
      ),

      _AddMarkerIntent: CallbackAction<_AddMarkerIntent>(
        onInvoke: (_) {
          onMarkerAdd();
          return null;
        },
      ),

      _JumpMarkerIntent: CallbackAction<_JumpMarkerIntent>(
        onInvoke: (i) {
          onMarkerJump(i.i1based);
          return null;
        },
      ),

      _PrevNextMarkerIntent: CallbackAction<_PrevNextMarkerIntent>(
        onInvoke: (i) {
          if (i.next) {
            onMarkerNext();
          } else {
            onMarkerPrev();
          }
          return null;
        },
      ),

      _PitchUpIntent: CallbackAction<_PitchUpIntent>(
        onInvoke: (_) {
          onPitchNudge(1);
          return null;
        },
      ),

      _PitchDownIntent: CallbackAction<_PitchDownIntent>(
        onInvoke: (_) {
          onPitchNudge(-1);
          return null;
        },
      ),

      _SpeedPresetIntent: CallbackAction<_SpeedPresetIntent>(
        onInvoke: (i) {
          onSpeedPreset(i.value);
          return null;
        },
      ),

      _TempoNudgeIntent: CallbackAction<_TempoNudgeIntent>(
        onInvoke: (i) {
          onSpeedNudge(i.deltaPercent);
          return null;
        },
      ),


      _ZoomIntent: CallbackAction<_ZoomIntent>(
        onInvoke: (i) {
          onZoom(i.zoomIn);
          return null;
        },
      ),

      _ZoomResetIntent: CallbackAction<_ZoomResetIntent>(
        onInvoke: (_) {
          onZoomReset();
          return null;
        },
      ),
    };
  }
}

/// ===============================================================
///  Intents
/// ===============================================================

class _PlayFromStartOrPauseIntent extends Intent {
  const _PlayFromStartOrPauseIntent();
}

class _ToggleLoopIntent extends Intent {
  const _ToggleLoopIntent();
}

class _SetLoopIntent extends Intent {
  final bool isA;
  const _SetLoopIntent(this.isA);
}

class _AddMarkerIntent extends Intent {
  const _AddMarkerIntent();
}

class _JumpMarkerIntent extends Intent {
  final int i1based;
  const _JumpMarkerIntent(this.i1based);
}

class _PrevNextMarkerIntent extends Intent {
  final bool next;
  const _PrevNextMarkerIntent(this.next);
}

class _PitchUpIntent extends Intent {
  const _PitchUpIntent();
}

class _PitchDownIntent extends Intent {
  const _PitchDownIntent();
}

class _SpeedPresetIntent extends Intent {
  final double value;
  const _SpeedPresetIntent(this.value);
}

class _TempoNudgeIntent extends Intent {
  final int deltaPercent;
  const _TempoNudgeIntent(this.deltaPercent);
}

class _ZoomIntent extends Intent {
  final bool zoomIn;
  const _ZoomIntent(this.zoomIn);
}

class _ZoomResetIntent extends Intent {
  const _ZoomResetIntent();
}
