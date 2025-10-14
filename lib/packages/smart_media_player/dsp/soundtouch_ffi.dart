// lib/packages/smart_media_player/dsp/soundtouch_ffi.dart
//
// v1.91.1 | FFI wrapper (Tempo & Pitch) with safe fallback
// - lookupFunction 호출을 심볼별 try/catch로 교정 (must_be_a_native_function_type 해결)
// - typedef들을 UpperCamelCase로 정리 (camel_case_types 해결)
// - macOS/Windows/Linux 후보 경로 탐색 유지
// - 미탐 시 NOP 동작

import 'dart:ffi' as ffi;
import 'dart:io' show Platform, File, Directory;
import 'package:path/path.dart' as p;

// ===== C symbols (native) =====================================================
typedef StCreateNative = ffi.Pointer<ffi.Void> Function();
typedef StDisposeNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef StSetSamplerateNative =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef StSetChannelsNative =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef StSetTempoNative = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double);
typedef StSetPitchSemiNative =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double);

// ===== Dart signatures ========================================================
typedef StCreateDart = ffi.Pointer<ffi.Void> Function();
typedef StDisposeDart = void Function(ffi.Pointer<ffi.Void>);
typedef StSetSamplerateDart = void Function(ffi.Pointer<ffi.Void>, int);
typedef StSetChannelsDart = void Function(ffi.Pointer<ffi.Void>, int);
typedef StSetTempoDart = void Function(ffi.Pointer<ffi.Void>, double);
typedef StSetPitchSemiDart = void Function(ffi.Pointer<ffi.Void>, double);

class SoundTouchDsp {
  SoundTouchDsp({required int sampleRate, required int channels}) {
    _init(sampleRate, channels);
  }

  Future<void> setTempo(double tempo) async {
    if (!_ok || _ctx == null || _stSetTempo == null) return;
    _stSetTempo!(_ctx!, tempo);
  }

  /// Pitch in semitones (-7.0 ~ +7.0)
  Future<void> setPitchSemiTones(double semitones) async {
    if (!_ok || _ctx == null || _stSetPitchSemi == null) return;
    _stSetPitchSemi!(_ctx!, semitones);
  }

  void dispose() {
    if (_ok && _ctx != null && _stDispose != null) {
      try {
        _stDispose!(_ctx!);
      } catch (_) {}
      _ctx = null;
    }
  }

  bool get isReady => _ok;

  // ---- internal ----
  bool _ok = false;
  ffi.DynamicLibrary? _lib;
  ffi.Pointer<ffi.Void>? _ctx;

  StCreateDart? _stCreate;
  StDisposeDart? _stDispose;
  StSetSamplerateDart? _stSetSampleRate;
  StSetChannelsDart? _stSetChannels;
  StSetTempoDart? _stSetTempo; // optional
  StSetPitchSemiDart? _stSetPitchSemi; // optional

  String? _bundleResourcesPath() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final res = Directory(
        p.normalize(p.join(exeDir.path, '..', 'Resources')),
      );
      if (res.existsSync()) return res.path;
    } catch (_) {}
    return null;
  }

  String? _bundleFrameworksPath() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final fw = Directory(
        p.normalize(p.join(exeDir.path, '..', 'Frameworks')),
      );
      if (fw.existsSync()) return fw.path;
    } catch (_) {}
    return null;
  }

  List<String> _candidateLibraryPaths() {
    final paths = <String>[];
    final macName = 'libsoundtouch_ffi.dylib';
    final winName = 'soundtouch_ffi.dll';
    final linuxName = 'libsoundtouch_ffi.so';
    final filename = Platform.isWindows
        ? winName
        : Platform.isLinux
        ? linuxName
        : macName;

    if (Platform.isMacOS) {
      final fw = _bundleFrameworksPath();
      final rs = _bundleResourcesPath();
      if (fw != null) paths.add(p.join(fw, filename));
      if (rs != null) paths.add(p.join(rs, filename));
    }

    // dev/build-common
    paths.add(filename);
    paths.add(p.join('native', 'build', filename));
    paths.add(p.join('build', filename));
    paths.add(p.join('.dart_tool', filename));

    return paths;
  }

  void _init(int sr, int ch) {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      _ok = false;
      return;
    }

    ffi.DynamicLibrary? lib;
    for (final path in _candidateLibraryPaths()) {
      try {
        lib = ffi.DynamicLibrary.open(path);
        break;
      } catch (_) {}
    }
    if (lib == null) {
      _ok = false;
      return;
    }

    try {
      _lib = lib;

      // Required symbols
      _stCreate = _lib!.lookupFunction<StCreateNative, StCreateDart>(
        'st_create',
      );
      _stDispose = _lib!.lookupFunction<StDisposeNative, StDisposeDart>(
        'st_dispose',
      );
      _stSetSampleRate = _lib!
          .lookupFunction<StSetSamplerateNative, StSetSamplerateDart>(
            'st_set_samplerate',
          );
      _stSetChannels = _lib!
          .lookupFunction<StSetChannelsNative, StSetChannelsDart>(
            'st_set_channels',
          );

      // Optional symbols (개발 중 미탐 시 NOP)
      try {
        _stSetTempo = _lib!.lookupFunction<StSetTempoNative, StSetTempoDart>(
          'st_set_tempo',
        );
      } catch (_) {
        _stSetTempo = null;
      }
      try {
        _stSetPitchSemi = _lib!
            .lookupFunction<StSetPitchSemiNative, StSetPitchSemiDart>(
              'st_set_pitch_semitones',
            );
      } catch (_) {
        _stSetPitchSemi = null;
      }

      _ctx = _stCreate!();
      if (_ctx == ffi.nullptr) {
        _ok = false;
        return;
      }

      _stSetSampleRate!(_ctx!, sr);
      _stSetChannels!(_ctx!, ch);

      _ok = true;
    } catch (_) {
      _ok = false;
    }
  }
}
