import 'dart:async';
import 'package:flutter/foundation.dart';
import 'audio_output_macos.dart';

class SoundTouchAudioChain {
  SoundTouchAudioChain._();
  static final instance = SoundTouchAudioChain._();
  final AudioOutputMacOS _audio = AudioOutputMacOS();

  double _lastSpeed = 1.0;
  double _lastPitch = 0.0;
  double _lastVol = 1.0;

  Stream<Duration> get positionStream => _audio.positionStream;

  Future<void> startFeedLoop() async {
    await _audio.init();
    await _audio.startFeedLoop();
    await apply(_lastSpeed, _lastPitch, _lastVol * 100);
  }

  Future<void> apply(double speed, double semi, double vol) async {
    final clampedSpeed = speed.clamp(0.5, 1.5);
    final clampedVol = (vol / 100.0).clamp(0.0, 1.5);
    _audio.setTempo(clampedSpeed);
    _audio.setPitch(semi);
    _audio.setVolume(clampedVol);
    _lastSpeed = clampedSpeed;
    _lastPitch = semi;
    _lastVol = clampedVol;
    debugPrint(
      '[SoundTouchChain] tempo=${clampedSpeed.toStringAsFixed(2)} '
      'pitch=${semi.toStringAsFixed(2)} vol=${clampedVol.toStringAsFixed(2)}',
    );
  }

  void dispose() => _audio.dispose();
}
