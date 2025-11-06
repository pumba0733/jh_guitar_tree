import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'engine_soundtouch_ffi.dart';

class AudioOutputMacOS {
  final SoundTouchFFI _soundtouch = SoundTouchFFI();
  bool _initialized = false;
  int _sampleRate = 44100;
  int _channels = 2;
  int _playedFrames = 0;

  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  Stream<Duration> get positionStream => _positionController.stream;

  SoundTouchFFI get soundtouch => _soundtouch;

  Future<void> init({int sampleRate = 44100, int channels = 2}) async {
    if (_initialized) return;
    _sampleRate = sampleRate;
    _channels = channels;
    _playedFrames = 0;
    debugPrint('[AudioOutputMacOS] 🎧 init sr=$sampleRate ch=$channels');
    _soundtouch.init(sampleRate: sampleRate, channels: channels);
    _soundtouch.startPlayback();
    _initialized = true;
  }

  Future<void> startFeedLoop() async {
    debugPrint('[AudioOutputMacOS] 🔄 startFeedLoop');
    const frame = 4096;
    final buffer = Float32List(frame * _channels);

    unawaited(
      Future(() async {
        while (_initialized) {
          try {
            final got = _soundtouch.receiveSamples(buffer, frame);
            if (got > 0) {
              _playedFrames += got;
              _soundtouch.enqueueToAudioQueue(buffer, got);

              final seconds = _playedFrames / _sampleRate;
              final pos = Duration(microseconds: (seconds * 1e6).round());
              if (!_positionController.isClosed) _positionController.add(pos);

              if (_playedFrames % 44100 == 0) {
                debugPrint('[🟢 PCM→AQ] ${_playedFrames ~/ 44100}s played');
              }
            } else {
              await Future.delayed(const Duration(milliseconds: 5));
            }
          } catch (e, st) {
            debugPrint('⚠️ [FeedLoop] $e\n$st');
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }
      }),
    );
  }

  void setTempo(double value) {
    _soundtouch.setTempo(value);
    debugPrint('[FFI] tempo=$value');
  }

  void setPitch(double value) {
    _soundtouch.setPitchSemiTones(value);
    debugPrint('[FFI] pitch=$value');
  }

  void setVolume(double value) {
    _soundtouch.setVolume(value);
    debugPrint('[FFI] volume=$value');
  }

  void dispose() {
    _soundtouch.dispose();
    _initialized = false;
    if (!_positionController.isClosed) _positionController.close();
  }
}
