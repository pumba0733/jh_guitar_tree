// lib/packages/smart_media_player/qa/smp_loop_stress_tester.dart
//
// Step 6-D — Loop Boundary Stress Tester
//

import 'dart:async';
import '../engine/engine_api.dart';
import '../loop/loop_executor.dart';

class SmpLoopStressTester {
  final LoopExecutor loop;
  Timer? _timer;
  final void Function(String log) onLog;

  SmpLoopStressTester({required this.loop, required this.onLog});

  void start() {
    stop();
    loop.start();
    onLog('[LoopTester] started.');
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) => _tick());
  }

  void stop() {
    loop.stop();
    _timer?.cancel();
    _timer = null;
    onLog('[LoopTester] stopped.');
  }

  void _tick() {
    final eng = EngineApi.instance;
    final pos = eng.position;
    final pa = eng.pendingAlignTarget;

    onLog(
      '[LoopTester] pos=$pos, '
      'A=${loop.loopA}, B=${loop.loopB}, '
      'remaining=${loop.remaining}, '
      'pendingAlign=$pa',
    );
  }
}
