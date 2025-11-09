import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'audio_output_macos.dart';

/// v3.40.2 — 정리본 (오류 0)
class SoundTouchAudioChain {
  SoundTouchAudioChain._();
  static final instance = SoundTouchAudioChain._();

  final AudioOutputMacOS _audio = AudioOutputMacOS();

  double _lastSpeed = 1.0;
  double _lastPitch = 0.0;
  double _lastVol = 1.0;

  Future<void> startFeedLoop() async {
    await _audio.init();
    await _audio.startFeedLoop(); // ✅ 존재함
    await apply(_lastSpeed, _lastPitch, _lastVol * 100);
  }

  Future<void> apply(double speed, double semi, double vol) async {
    final s = speed.clamp(0.5, 1.5);
    final v = (vol / 100.0).clamp(0.0, 1.5);
    _audio.setTempo(s);
    _audio.setPitch(semi);
    _audio.setVolume(v);
  }

  void feedPcm(Float32List pcm) => _audio.feedPCM(pcm);
  void dispose() => _audio.dispose();
}
