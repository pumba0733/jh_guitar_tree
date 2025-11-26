// lib/packages/smart_media_player/qa/smp_engine_drift_logger.dart
//
// Step 6-D — Engine Drift Logger
// 목적: audioAbs(position) vs videoPosition vs pendingAlignTarget drift 관찰
//

import 'dart:async';
import '../engine/engine_api.dart';

class SmpEngineDriftLogger {
  Timer? _timer;
  final Duration interval;
  final void Function(String log) onLog;

  SmpEngineDriftLogger({
    this.interval = const Duration(milliseconds: 50),
    required this.onLog,
  });

  void start() {
    stop();
    _timer = Timer.periodic(interval, (_) => _tick());
    onLog('[DriftLogger] started.');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    onLog('[DriftLogger] stopped.');
  }

  void _tick() {
    final eng = EngineApi.instance;
    final audioPos = eng.position;
    final videoPos = eng.videoPosition;
    final ps = eng.pendingSeekTarget;
    final pa = eng.pendingAlignTarget;

    final driftMs = (videoPos - audioPos).inMilliseconds.abs();

    onLog(
      '[Drift] audio=$audioPos, video=$videoPos, driftMs=$driftMs, '
      'pendingSeek=$ps, pendingAlign=$pa',
    );
  }
}
