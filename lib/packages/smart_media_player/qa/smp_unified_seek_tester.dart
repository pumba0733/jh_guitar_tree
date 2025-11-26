// lib/packages/smart_media_player/qa/smp_unified_seek_tester.dart
//
// Step 6-D — Unified Seek Stress Tester
//

import 'dart:async';
import '../engine/engine_api.dart';

class SmpUnifiedSeekTester {
  Timer? _timer;
  final Duration step;
  final void Function(String log) onLog;

  Duration _cur = Duration.zero;

  SmpUnifiedSeekTester({
    this.step = const Duration(milliseconds: 200),
    required this.onLog,
  });

  void start() {
    stop();
    onLog('[SeekTester] started.');
    _timer = Timer.periodic(step, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    onLog('[SeekTester] stopped.');
  }

  Future<void> _tick() async {
    final eng = EngineApi.instance;
    final dur = eng.duration;
    if (dur == Duration.zero) return;

    _cur += const Duration(milliseconds: 500);
    if (_cur > dur) _cur = Duration.zero;

    final beforePend = eng.pendingSeekTarget;
    await eng.seekUnified(_cur);
    final afterPend = eng.pendingSeekTarget;

    onLog(
      '[SeekTester] seek→$_cur, '
      'beforePend=$beforePend, afterPend=$afterPend, '
      'pos=${eng.position}',
    );
  }
}
