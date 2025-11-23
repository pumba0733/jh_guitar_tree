// ===============================================================
//  AudioOutputMacOS — v3.41.26  (C++ 단일파일과 100% 정합)
// ===============================================================

import 'dart:typed_data';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' as ffi;
import 'package:flutter/foundation.dart';

import 'engine_soundtouch_ffi.dart';

class AudioOutputMacOS {
  bool _initialized = false;
  bool _playing = false;

  // ----------------------------------------------------------
  // Init — st_create()가 ma_device_start까지 포함
  // ----------------------------------------------------------
  Future<void> init() async {
    if (_initialized) return;
    try {
      st_create();
      _initialized = true;
      _playing = true;
      debugPrint('[AudioOutputMacOS] ✅ init (st_create = start)');
    } catch (e) {
      debugPrint('[AudioOutputMacOS] ❌ init failed: $e');
      rethrow;
    }
  }

  // ----------------------------------------------------------
  // Start — 별도 start 없음 → st_create 재호출
  // ----------------------------------------------------------
  void start() {
    if (!_initialized) {
      init();
      return;
    }
    if (_playing) return;

    try {
      st_create();
      _playing = true;
      debugPrint('[AudioOutputMacOS] ▶ start');
    } catch (e) {
      debugPrint('[AudioOutputMacOS] ❌ start error: $e');
    }
  }

  // ----------------------------------------------------------
  // Stop — C++ st_dispose()
  // ----------------------------------------------------------
  void stop() {
    if (!_playing) return;
    try {
      st_dispose();
      _initialized = false;
      _playing = false;
      debugPrint('[AudioOutputMacOS] ⏹ stopped');
    } catch (e) {
      debugPrint('[AudioOutputMacOS] ⚠ stop error: $e');
    }
  }

  // ----------------------------------------------------------
  // Tempo / Pitch / Volume
  // ----------------------------------------------------------
  void setTempo(double v) {
    if (!_initialized) return;
    st_setTempo(v.clamp(0.5, 1.5));
  }

  void setPitch(double semi) {
    if (!_initialized) return;
    st_setPitch(semi.clamp(-12.0, 12.0));
  }

  void setVolume(double v) {
    if (!_initialized) return;
    st_setVolume(v.clamp(0.0, 1.5));
  }

  // ----------------------------------------------------------
  // PCM Feed → st_feedPcm(ptr, frames)
  // ----------------------------------------------------------
  void feedPcm(Float32List pcm) {
    if (!_initialized || pcm.isEmpty) return;
    final ptr = ffi.calloc<ffi.Float>(pcm.length);
    try {
      for (int i = 0; i < pcm.length; i++) {
        ptr[i] = pcm[i];
      }
      st_feedPcm(ptr, pcm.length ~/ 2);
    } catch (e) {
      debugPrint('[AudioOutputMacOS] ⚠ feedPcm error: $e');
    } finally {
      ffi.calloc.free(ptr);
    }
  }

  // ----------------------------------------------------------
  // Playback Time
  // ----------------------------------------------------------
  double getPlaybackTime() {
    if (!_initialized) return 0.0;
    try {
      return st_getPlaybackTime();
    } catch (_) {
      return 0.0;
    }
  }

  // ----------------------------------------------------------
  // Dispose
  // ----------------------------------------------------------
  void dispose() {
    try {
      st_dispose();
    } catch (_) {}
    _initialized = false;
    _playing = false;
  }

  bool get isPlaying => _playing;
  bool get isInitialized => _initialized;

  // ----------------------------------------------------------
  // SeekTo — move playback pointer (seconds)
  // ----------------------------------------------------------
  void seekTo(double seconds) {
    if (!_initialized) return;
    try {
      st_seekTo(seconds); // C++ 바인딩 함수
      debugPrint('[AudioOutputMacOS] ▶ seekTo($seconds)');
    } catch (e) {
      debugPrint('[AudioOutputMacOS] ⚠ seekTo error: $e');
    }
  }

}
