/// 🎧 SoundTouchAudioChain v3.41.11 — Final
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'audio_output_macos.dart';

class SoundTouchAudioChain {
  SoundTouchAudioChain._();
  static final SoundTouchAudioChain instance = SoundTouchAudioChain._();

  final AudioOutputMacOS _audio = AudioOutputMacOS();

  bool _ready = false;
  bool _started = false;

  double _lastTempo = 1.0;
  double _lastPitch = 0.0;
  double _lastVol = 1.0;

  final _timeCtrl = StreamController<double>.broadcast();
  Stream<double> get playbackTimeStream => _timeCtrl.stream;
  Stream<Float32List>? _pcmStream;


  Timer? _timer;
  StreamSubscription<Float32List>? _feedSub;

  // === For Debug / Waveform ===
  Float32List _lastBuffer = Float32List(0);
  double _lastRms = 0.0;

  Float32List get lastBuffer => _lastBuffer;
  double get lastRms => _lastRms;

  Future<void> init() async {
    if (_ready) return;
    await _audio.init(); // st_create()
    _ready = true;
  }

  Future<void> start({required Stream<Float32List> pcmStream}) async {
    if (!_ready) await init();
    _pcmStream = pcmStream; // 🔥 stream 원본 저장
    _audio.start();
    _started = true;

    // playbackTime poll
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      final t = _audio.getPlaybackTime();
      _timeCtrl.add(t);
    });

    await _feedSub?.cancel();
    _feedSub = pcmStream.listen(_processPcm);
  }

  void _processPcm(Float32List pcm) {
    if (!_started) return;

    // feed to native SoundTouch
    _audio.feedPcm(pcm);

    // Dart-only debug
    _lastBuffer = pcm;
    _lastRms = _calcRms(pcm);
  }

  double _calcRms(Float32List pcm) {
    double sum = 0.0;
    final N = pcm.length ~/ 2; // mono RMS
    if (N <= 0) return 0.0;

    for (int i = 0; i < pcm.length; i += 2) {
      final v = pcm[i];
      sum += v * v;
    }
    return sqrt(sum / N);
  }

  void setTempo(double v) {
    _lastTempo = v;
    _audio.setTempo(v);
  }

  void setPitch(double v) {
    _lastPitch = v;
    _audio.setPitch(v);
  }

  void setVolume(double v) {
    _lastVol = v;
    _audio.setVolume(v);
  }

  Future<void> stop() async {
    if (!_started) return;

    await _feedSub?.cancel();
    _feedSub = null;

    _timer?.cancel();
    _timer = null;

    _audio.stop();
    _started = false;
  }

  void dispose() {
    _feedSub?.cancel();
    _timer?.cancel();
    _audio.dispose();
    _timeCtrl.close();
  }

  // ===== duration =====
  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  void setDuration(Duration d) {
    _duration = d;
  }

  bool get isStarted => _started;
  double get playbackTime => _audio.getPlaybackTime();

  Future<void> startFrom(Duration d) async {
    if (!_ready) await init();

    final sec = d.inMilliseconds / 1000.0;

    // 1) native seek
    try {
      _audio.seekTo(sec);
    } catch (e) {
      debugPrint('[SoundTouch] ⚠ seekTo error: $e');
    }

    // 2) 이미 재생 중이면 여기서 끝
    if (_started) return;

    // 3) 재시작 — 반드시 기존 PCM stream을 그대로 전달해야 함
    if (_feedSub == null) {
      debugPrint('[SoundTouch] ⚠ startFrom called but no PCM feed');
      return;
    }

    // 기존 feedStream을 다시 구할 방법:
    final stream = _pcmStream!.asBroadcastStream();

    await start(pcmStream: stream);
  }

}
