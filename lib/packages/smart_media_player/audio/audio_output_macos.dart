// lib/packages/smart_media_player/audio/audio_output_macos.dart
// v3.35.6 — Async SoundTouch PCM Output (macOS)
// Author: GPT-5 (JH_GuitarTree Core)

import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'engine_soundtouch_ffi.dart';

/// Handles PCM processing and playback through SoundTouch FFI.
class AudioOutputMacOS {
  final SoundTouchFFI _soundtouch = SoundTouchFFI();

  bool _initialized = false;
  int _sampleRate = 44100;
  int _channels = 2;
  double _tempo = 1.0;
  double _pitch = 0.0;
  int _volume = 100;

  Future<void> init({int sampleRate = 44100, int channels = 2}) async {
    if (_initialized) return;
    _sampleRate = sampleRate;
    _channels = channels;

    debugPrint('[AudioOutputMacOS] Initializing SoundTouch...');
    _soundtouch.init(sampleRate: _sampleRate, channels: _channels);
    _initialized = true;
  }

  /// Updates the playback parameters dynamically
  void applySettings({double? tempo, double? pitch, int? volume}) {
    if (!_initialized) return;
    if (tempo != null) {
      _tempo = tempo;
      _soundtouch.setTempo(tempo);
    }
    if (pitch != null) {
      _pitch = pitch;
      _soundtouch.setPitchSemiTones(pitch);
    }
    if (volume != null) {
      _volume = volume.clamp(0, 100);
    }
    debugPrint(
      '[AudioOutputMacOS] _applyAudioChain tempo=$_tempo pitch=$_pitch vol=$_volume',
    );
  }

  /// Feeds PCM samples to SoundTouch
  void processPCM(Float32List pcm) {
    if (!_initialized) return;
    _soundtouch.putSamples(pcm);
  }

  /// Starts playback asynchronously (no UI blocking)
  Future<void> startPlayback() async {
    if (!_initialized) return;
    debugPrint('[AudioOutputMacOS] ▶️ startPlayback (async FFI)');
    await _soundtouch.startPlaybackAsync();
  }

  /// Stops AudioQueue playback
  void stopPlayback() {
    if (!_initialized) return;
    debugPrint('[AudioOutputMacOS] ⏹️ stopPlayback');
    _soundtouch.stop();
  }

  /// Cleanup resources
  void dispose() {
    if (!_initialized) return;
    _soundtouch.dispose();
    _initialized = false;
    debugPrint('[AudioOutputMacOS] 🔚 disposed');
  }
}
