import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

class SoundTouchFFI {
  final DynamicLibrary dylib;

  late final Pointer<Void> Function() stCreate;
  late final void Function(Pointer<Void>) stDestroy;
  late final void Function(Pointer<Void>, double) stSetTempo;
  late final void Function(Pointer<Void>, double) stSetPitch;
  late final void Function(Pointer<Void>, double) stSetRate;
  late final void Function(Pointer<Void>, int) stSetSampleRate;
  late final void Function(Pointer<Void>, int) stSetChannels;
  late final void Function(Pointer<Void>, Pointer<Float>, int) stPlaySamples;
  late final void Function() stAudioStop;

  SoundTouchFFI(this.dylib) {
    stCreate = dylib
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'st_create',
        );
    stDestroy = dylib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('st_destroy');
    stSetTempo = dylib
        .lookupFunction<
          Void Function(Pointer<Void>, Float),
          void Function(Pointer<Void>, double)
        >('st_set_tempo');
    stSetPitch = dylib
        .lookupFunction<
          Void Function(Pointer<Void>, Float),
          void Function(Pointer<Void>, double)
        >('st_set_pitch_semitones');
    stSetRate = dylib
        .lookupFunction<
          Void Function(Pointer<Void>, Float),
          void Function(Pointer<Void>, double)
        >('st_set_rate');
    stSetSampleRate = dylib
        .lookupFunction<
          Void Function(Pointer<Void>, Int32),
          void Function(Pointer<Void>, int)
        >('st_set_sample_rate');
    stSetChannels = dylib
        .lookupFunction<
          Void Function(Pointer<Void>, Int32),
          void Function(Pointer<Void>, int)
        >('st_set_channels');
    stPlaySamples = dylib
        .lookupFunction<
          Void Function(Pointer<Void>, Pointer<Float>, Uint32),
          void Function(Pointer<Void>, Pointer<Float>, int)
        >('st_play_samples');
    stAudioStop = dylib.lookupFunction<Void Function(), void Function()>(
      'st_audio_stop',
    );
  }

  Pointer<Void> create() => stCreate();
  void dispose(Pointer<Void> ptr) => stDestroy(ptr);

  void configure(Pointer<Void> ptr, {double tempo = 1.0, double pitch = 0.0}) {
    stSetTempo(ptr, tempo);
    stSetPitch(ptr, pitch);
    stSetSampleRate(ptr, 44100);
    stSetChannels(ptr, 2);
  }

  void play(Pointer<Void> ptr, Float32List samples) {
    final p = malloc.allocate<Float>(samples.length * sizeOf<Float>());
    p.asTypedList(samples.length).setAll(0, samples);
    stPlaySamples(ptr, p, samples.length);
    malloc.free(p);
  }

  void stop() => stAudioStop();
}
