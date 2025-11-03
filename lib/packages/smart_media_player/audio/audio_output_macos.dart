// lib/packages/smart_media_player/audio/audio_output_macos.dart
// v3.35.0 — SoundTouch PCM Integration Phase
// Author: GPT-5 (JHGuitarTree Core)
// Purpose: Connect mpv PCM stream → SoundTouch FFI → AudioSink (macOS)

import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:guitartree/packages/smart_media_player/audio/engine_soundtouch_ffi.dart';
import 'package:flutter/services.dart';

/// Handles PCM processing and playback through SoundTouch FFI.
class AudioOutputMacOS {
  final SoundTouchFFI _soundtouch = SoundTouchFFI();

  bool _initialized = false;
  int _sampleRate = 44100;
  int _channels = 2;

  Future<void> init({int sampleRate = 44100, int channels = 2}) async {
    if (_initialized) return;
    _sampleRate = sampleRate;
    _channels = channels;
    debugPrint('[AudioOutputMacOS] Initializing SoundTouch...');
    _soundtouch.init(sampleRate: sampleRate, channels: channels);
    _initialized = true;
  }

  void setTempo(double tempo) {
    if (!_initialized) return;
    debugPrint('[AudioOutputMacOS] setTempo($tempo)');
    _soundtouch.setTempo(tempo);
  }

  void setPitch(double semitones) {
    if (!_initialized) return;
    debugPrint('[AudioOutputMacOS] setPitchSemiTones($semitones)');
    _soundtouch.setPitchSemiTones(semitones);
  }

  /// Processes raw PCM (int16) through SoundTouch and returns transformed samples.
  Future<Float32List> processPCM(Uint8List pcmBytes) async {
    if (!_initialized) {
      debugPrint('[AudioOutputMacOS] processPCM() called before init');
      return Float32List(0);
    }

    // Convert bytes (16-bit PCM) to Float32 samples
    final int16Data = Int16List.view(pcmBytes.buffer);
    final Float32List floatData = Float32List(int16Data.length)
      ..setAll(0, int16Data.map((v) => v / 32768.0));

    // Send to SoundTouch
    _soundtouch.putSamples(floatData);

    // Receive processed samples
    final Float32List output = _soundtouch.receiveSamples();

    debugPrint(
      '[FFI] put=${floatData.length} → recv=${output.length} | tempo/pitch=${_soundtouch.tempo}/${_soundtouch.pitch}',
    );

    return output;
  }

  /// Placeholder for playback sink
  Future<void> play(Float32List samples) async {
    // TODO: Implement PCM playback (FlutterAudioSink or custom)
    debugPrint('[AudioOutputMacOS] play(${samples.length} samples)');
  }

  /// Called periodically or from engine chain to feed new PCM blocks
  Future<void> onPcmInput(Uint8List pcmBytes) async {
    final out = await processPCM(pcmBytes);
    await play(out);
  }

  void dispose() {
    debugPrint('[AudioOutputMacOS] Disposing SoundTouch.');
    _soundtouch.dispose();
    _initialized = false;
  }
}
