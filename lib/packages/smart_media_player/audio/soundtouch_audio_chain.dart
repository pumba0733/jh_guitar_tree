import 'package:flutter/foundation.dart';
import 'audio_output_macos.dart';

class SoundTouchAudioChain {
  SoundTouchAudioChain._internal();
  static final SoundTouchAudioChain instance = SoundTouchAudioChain._internal();

  final AudioOutputMacOS _audio = AudioOutputMacOS();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    await _audio.init(sampleRate: 44100, channels: 2);
    await _audio.start();
    _ready = true;
  }

  void setTempoPitch(double tempo, double semi) {
    if (!_ready) return;
    debugPrint('[CHAIN] tempo=$tempo semi=$semi');
    _audio.soundtouch.setTempo(tempo);
    _audio.soundtouch.setPitchSemiTones(semi);
  }

  void apply(double tempo, double semi) {
    if (!_ready) return;
    debugPrint('[CHAIN] apply tempo=$tempo semi=$semi');
    _audio.soundtouch.setTempo(tempo);
    _audio.soundtouch.setPitchSemiTones(semi);
  }


  void processPCM(Float32List pcm) {
    if (!_ready) return;
    _audio.soundtouch.putSamples(pcm);
  }

  void startMockFeed() {
    if (!_ready) return;
    _audio.feedMockSinewave();
  }
  
  Future<void> startFeedLoop() async {
    if (!_ready) return;
    debugPrint('[CHAIN] 🔄 Starting PCM → AudioQueue feed loop');
    await _audio.startFeedLoop();
  }


  void dispose() {
    _audio.dispose();
    _ready = false;
  }
  
}
