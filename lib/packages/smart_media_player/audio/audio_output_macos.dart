import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'engine_soundtouch_ffi.dart';

class AudioOutputMacOS {
  final SoundTouchFFI _soundtouch = SoundTouchFFI();
  bool _initialized = false;
  int _sampleRate = 44100;
  int _channels = 2;

  // ✅ 외부에서 접근 가능하도록 getter 추가
  SoundTouchFFI get soundtouch => _soundtouch;

  Future<void> init({int sampleRate = 44100, int channels = 2}) async {
    if (_initialized) return;
    _sampleRate = sampleRate;
    _channels = channels;
    debugPrint('[AudioOutputMacOS] Initializing SoundTouch...');
    _soundtouch.init(sampleRate: sampleRate, channels: channels);
    _initialized = true;
    debugPrint('[AudioOutputMacOS] ✅ Initialized');
  }

  Future<void> start() async {
    debugPrint('[AudioOutputMacOS] ▶️ AudioQueue start() called');
    await _soundtouch.startPlaybackAsync();
    debugPrint('[AudioOutputMacOS] ▶️ AudioQueue started');
  }

  Future<void> startFeedLoop() async {
    debugPrint('[AudioOutputMacOS] 🔄 PCM feed loop start');
    const frame = 4096;
    final buffer = Float32List(frame * _channels);

    while (true) {
      final got = _soundtouch.receiveSamples(buffer, frame);
      if (got > 0) {
        debugPrint('[🟢 PCM→AQ] sending $got frames');
        _soundtouch.enqueueToAudioQueue(buffer, got);
      } else {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }
  }


  Future<void> feedMockSinewave() async {
    debugPrint('[FFI] 🔗 Mock PCM feed connected');
    const double freq = 440.0;
    final samples = Float32List(4096);
    double phase = 0.0;
    while (true) {
      for (int i = 0; i < samples.length; i++) {
        samples[i] = (0.2 * sin(2 * pi * phase));
        phase += freq / _sampleRate;
        if (phase > 1.0) phase -= 1.0;
      }
      _soundtouch.putSamples(samples);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  void dispose() {
    _soundtouch.dispose();
    _initialized = false;
  }
}
