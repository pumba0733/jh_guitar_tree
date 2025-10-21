//lib/packages/smart_media_player/waveform/analyzer/fftw_bridge.dart

// Native bridge (macOS: process symbol link)
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart' as c;

/// C: int fftw_analyze_bands_f32(float*, float*, int32, int32, int32, int32, int32, int32, float*, float*, int32*)
typedef _AnalyzeNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Float>, // left
      ffi.Pointer<ffi.Float>, // right (nullable 대응: mono면 left 복제)
      ffi.Int32, // samples
      ffi.Int32, // sample_rate
      ffi.Int32, // fft_size
      ffi.Int32, // hop_size
      ffi.Int32, // bands
      ffi.Int32, // a_weighting
      ffi.Pointer<ffi.Float>, // out_left
      ffi.Pointer<ffi.Float>, // out_right
      ffi.Pointer<ffi.Int32>, // out_frames
    );
typedef _Analyze =
    int Function(
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
      int,
      int,
      int,
      int,
      int,
      int,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Int32>,
    );

class FftwBridge {
  late final ffi.DynamicLibrary _lib;
  late final _Analyze _analyze;

  FftwBridge() {
    _lib = Platform.isMacOS
        ? ffi.DynamicLibrary.process()
        : throw UnsupportedError('FFTW bridge is macOS-only for now');

    _analyze = _lib.lookupFunction<_AnalyzeNative, _Analyze>(
      'fftw_analyze_bands_f32',
    );
  }

  int analyze({
    required List<double> left,
    required List<double>? right,
    required int sampleRate,
    required int fftSize,
    required int hopSize,
    required int bands,
    required bool aWeighting,
    required List<double> outLeft,
    required List<double> outRight,
    required int expectedFrames,
  }) {
    final n = left.length;
    final pL = c.calloc<ffi.Float>(n);
    final pR = c.calloc<ffi.Float>(n);
    final pOL = c.calloc<ffi.Float>(expectedFrames * bands);
    final pOR = c.calloc<ffi.Float>(expectedFrames * bands);
    final pF = c.calloc<ffi.Int32>(1);

    for (var i = 0; i < n; i++) {
      pL[i] = left[i].toDouble();
    }
    if (right == null || right.isEmpty) {
      for (var i = 0; i < n; i++) pR[i] = left[i].toDouble();
    } else {
      final m = right.length < n ? right.length : n;
      var i = 0;
      for (; i < m; i++) pR[i] = right[i].toDouble();
      for (; i < n; i++) pR[i] = 0.0;
    }
    print(
      '[FFT] bridge call: n=$n sr=$sampleRate fft=$fftSize hop=$hopSize bands=$bands expFrames=$expectedFrames',
    );
    final rc = _analyze(
      pL,
      pR,
      n,
      sampleRate,
      fftSize,
      hopSize,
      bands,
      aWeighting ? 1 : 0,
      pOL,
      pOR,
      pF,
    );
    print('[FFT] bridge done rc=$rc frames=${pF.value}');

    final outFrames = pF.value;
    final total = outFrames * bands;
    outLeft
      ..clear()
      ..addAll(List<double>.generate(total, (i) => pOL[i]));
    outRight
      ..clear()
      ..addAll(List<double>.generate(total, (i) => pOR[i]));

    c.calloc.free(pL);
    c.calloc.free(pR);
    c.calloc.free(pOL);
    c.calloc.free(pOR);
    c.calloc.free(pF);

    return rc;
  }
}
