// lib/packages/smart_media_player/qa/smp_ffrw_tick_profiler.dart
//
// Step 6-D — FFRW Tick Stability Profiler
//

import 'dart:async';
import '../engine/engine_api.dart';

class SmpFfRwTickProfiler {
  Timer? _timer;
  Duration? _lastPos;
  final void Function(String log) onLog;

  SmpFfRwTickProfiler({required this.onLog});

  void start() {
    stop();
    onLog('[FfRwProfiler] started.');
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    onLog('[FfRwProfiler] stopped.');
  }

  void _tick() {
    final eng = EngineApi.instance;
    final pos = eng.position;

    if (_lastPos != null) {
      final diff = (pos - _lastPos!).inMilliseconds;
      onLog(
        '[FfRwProfiler] pos=$pos, Δ=${diff}ms, '
        'pendingSeek=${eng.pendingSeekTarget}, '
        'pendingAlign=${eng.pendingAlignTarget}',
      );
    }

    _lastPos = pos;
  }
}
