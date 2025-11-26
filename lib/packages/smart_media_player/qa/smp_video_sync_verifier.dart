// lib/packages/smart_media_player/qa/smp_video_sync_verifier.dart
//
// Step 6-D — Video Sync Verifier
//

import 'dart:async';
import '../engine/engine_api.dart';
import '../video/video_sync_service.dart';

class SmpVideoSyncVerifier {
  Timer? _timer;
  final Duration interval;
  final void Function(String log) onLog;

  SmpVideoSyncVerifier({
    this.interval = const Duration(milliseconds: 40),
    required this.onLog,
  });

  void start() {
    stop();
    onLog('[VideoVerifier] started.');
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    onLog('[VideoVerifier] stopped.');
  }

  void _tick() {
    final eng = EngineApi.instance;
    final audioPos = eng.position;
    final videoPos = VideoSyncService.instance.videoPosition;

    final driftMs = (videoPos - audioPos).inMilliseconds.abs();

    onLog(
      '[VideoVerifier] audio=$audioPos, video=$videoPos, drift=$driftMs ms, '
      'pendingSeek=${eng.pendingSeekTarget}, '
      'pendingAlign=${eng.pendingAlignTarget}',
    );
  }
}
