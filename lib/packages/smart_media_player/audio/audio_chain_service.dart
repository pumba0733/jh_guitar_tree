// lib/packages/smart_media_player/audio/audio_chain_service.dart
//
// SmartMediaPlayer v3.41 — Step 4-2
// SoundTouch Layer 완전 분리: decode / duration / feed / chain control
//
// 책임:
//  - decodeToFloat32(path) 호출 (AudioDecoder 이용)
//  - wav duration 계산
//  - PCM chunk feed 스트림 생성
//  - SoundTouchAudioChain.start / startFrom / stop 관리
//  - playbackTime / duration 재노출
//
// EngineApi는 이 서비스를 통해서만 SoundTouch와 통신한다.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import '../audio/audio_decoder.dart';
import '../../smart_media_player/audio/soundtouch_audio_chain.dart' as ac;

class AudioChainService {
  AudioChainService._();
  static final AudioChainService instance = AudioChainService._();

  final ac.SoundTouchAudioChain _chain = ac.SoundTouchAudioChain.instance;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  double _lastPlaybackTime = 0.0;
  double get lastPlaybackTime => _lastPlaybackTime;

  Stream<double> get playbackTime$ {
    return _chain.playbackTimeStream.map((v) {
      _lastPlaybackTime = v;
      return v;
    });
  }

  // ================================================================
  // PUBLIC: decode + feed + duration
  // ================================================================
  Future<(Float32List pcm, Duration duration, Stream<Float32List> feed)>
  decodeAndPrepare(String path) async {
    // 1) PCM 디코드
    final pcm = await AudioDecoder.decodeToFloat32(path);

    // 2) Duration 계산
    const sr = 44100;
    const ch = 2;
    final totalSamples = pcm.length / ch;
    final sec = totalSamples / sr;
    _duration = Duration(milliseconds: (sec * 1000).round());

    // 3) chunk feed stream 생성
    final ctl = StreamController<Float32List>();
    const chunk = 4096 * 2;

    () async {
      for (int i = 0; i < pcm.length; i += chunk) {
        final end = math.min(i + chunk, pcm.length);
        ctl.add(pcm.sublist(i, end));
        await Future.delayed(Duration.zero);
      }
      await ctl.close();
    }();

    return (pcm, _duration, ctl.stream);
  }

  // ================================================================
  // PUBLIC: chain control
  // ================================================================
  Future<void> start(Stream<Float32List> feed) async {
    await _chain.start(pcmStream: feed);
  }

  Future<void> stop() async {
    await _chain.stop();
  }

  Future<void> startFrom(Duration d) async {
    await _chain.startFrom(d);
  }

  // ================================================================
  // PUBLIC: tempo / pitch / volume
  // ================================================================
  Future<void> setTempo(double v) async => _chain.setTempo(v);
  Future<void> setPitch(double semi) async => _chain.setPitch(semi);
  Future<void> setVolume(double v01) async => _chain.setVolume(v01);

  // ================================================================
  // RESTORE STATE
  // ================================================================
  Future<void> restoreState({
    required double tempo,
    required int pitchSemi,
    required double volume,
  }) async {
    _chain.setTempo(tempo);
    _chain.setPitch(pitchSemi.toDouble());
    _chain.setVolume(volume);
  }

  // ================================================================
  // internal for EngineApi
  // ================================================================
  void setDuration(Duration d) {
    _duration = d;
    _chain.setDuration(d);
  }

  bool get isStarted => _chain.isStarted;
}
