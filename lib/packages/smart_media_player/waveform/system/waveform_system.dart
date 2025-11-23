//lib/packages/smart_media_player/waveform/system/waveform_system.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../../audio/soundtouch_audio_chain.dart';

class WfMarker {
  final Duration time;
  final String? label;
  final Color? color;
  final bool repeat;
  const WfMarker(this.time, [this.label, this.color, this.repeat = false]);
  const WfMarker.named({
    required this.time,
    this.label,
    this.color,
    this.repeat = false,
  });
}

class WaveformController {
  StreamSubscription<double>? _posSub;
  // ===== Timeline =====
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  // ===== Viewport (0~1 frac) =====
  final ValueNotifier<double> viewStart = ValueNotifier(0.0);
  final ValueNotifier<double> viewWidth = ValueNotifier(1.0);

  // ===== Loop (player state) =====
  final ValueNotifier<Duration?> loopA = ValueNotifier<Duration?>(null);
  final ValueNotifier<Duration?> loopB = ValueNotifier<Duration?>(null);
  final ValueNotifier<bool> loopOn = ValueNotifier<bool>(false);
  final ValueNotifier<int> loopRepeat = ValueNotifier<int>(0);

  // ===== Selection (visual-only) =====
  final ValueNotifier<Duration?> selectionA = ValueNotifier<Duration?>(null);
  final ValueNotifier<Duration?> selectionB = ValueNotifier<Duration?>(null);

  // ===== Markers =====
  final ValueNotifier<List<WfMarker>> markers = ValueNotifier<List<WfMarker>>(
    <WfMarker>[],
  );

  // ===== Start Cue =====
  final ValueNotifier<Duration?> startCue = ValueNotifier<Duration?>(null);

  // ===== Bridge callbacks (Panel -> Screen/Player) =====
  void Function(Duration t)? onSeek; // click seek
  void Function(Duration a, Duration b)? onLoopSet; // drag end => loop
  void Function(Duration t)? onStartCueSet; // start cue set
  void Function()? onPause; // optional hook

  // ===== Mutators =====
  void updateFromPlayer({Duration? pos, Duration? dur}) {
    if (pos != null) position.value = pos;
    if (dur != null) duration.value = dur;
  }

  void setViewport({required double start, required double width}) {
    viewStart.value = start.clamp(0.0, 1.0);
    viewWidth.value = width.clamp(0.0, 1.0);
  }

  void setLoop({Duration? a, Duration? b, bool? on}) {
    if (a != null) loopA.value = a;
    if (b != null) loopB.value = b;
    if (on != null) loopOn.value = on;
  }

  void setStartCue(Duration t) {
    startCue.value = t;
    onStartCueSet?.call(t);
  }

  void setMarkers(List<WfMarker> list) {
    markers.value = list;
  }

  void bindToAudioChain(SoundTouchAudioChain chain) {
    _posSub?.cancel(); // ✅ 기존 리스너 중복 방지
    _posSub = chain.playbackTimeStream.listen((t) {
      position.value = Duration(milliseconds: (t * 1000).toInt());
    });
    // durationStream은 현재 AudioChain에 없음
  }

  void attachTo(SoundTouchAudioChain chain) {
    bindToAudioChain(chain);
    updateFromPlayer(dur: chain.duration);
  }

  void dispose() {
    _posSub?.cancel();
  }

  // ===== debug (optional) =====
  bool debugTrackViewport = false;
  DateTime? _lastVpLogAt;
  void _vpLog(String s) {
    if (!debugTrackViewport) return;
    final now = DateTime.now();
    if (_lastVpLogAt == null ||
        now.difference(_lastVpLogAt!) > const Duration(milliseconds: 300)) {
      // ignore: avoid_print
      print('[WaveformController] $s');
      _lastVpLogAt = now;
    }
  }

  void setDuration(Duration d) {
    duration.value = d;
  }

}
