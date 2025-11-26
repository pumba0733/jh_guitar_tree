// lib/packages/smart_media_player/qa/smp_long_session_verifier.dart
//
// Step 6-D — Long Session Stability Verifier
//

import 'dart:async';
import '../engine/engine_api.dart';
import '../video/video_sync_service.dart';

class SmpLongSessionVerifier {
  Timer? _timer;
  final void Function(String log) onLog;

  Duration? _prevAudio;
  Duration? _prevVideo;

  SmpLongSessionVerifier({required this.onLog});

  void start() {
    stop();
    onLog('[LongSession] started.');
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    onLog('[LongSession] stopped.');
  }

  void _tick() {
    final eng = EngineApi.instance;

    final audioPos = eng.position;
    final videoPos = VideoSyncService.instance.videoPosition;

    if (_prevAudio != null) {
      final da = audioPos - _prevAudio!;
      final dv = videoPos - _prevVideo!;
      onLog(
        '[LongSession] audioΔ=$da, videoΔ=$dv, '
        'drift=${(videoPos - audioPos).inMilliseconds.abs()} ms, '
        'duration=${eng.duration}, '
        'pendingSeek=${eng.pendingSeekTarget}, '
        'pendingAlign=${eng.pendingAlignTarget}',
      );
    }

    _prevAudio = audioPos;
    _prevVideo = videoPos;
  }
}
