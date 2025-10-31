// lib/packages/smart_media_player/audio/engine_soundtouch_ffi.dart
// v3.33.1 | Dart FFI binding for SoundTouch
import 'dart:ffi' as ffi;
import 'dart:io';

// ───────────────────────────────
// 1️⃣ Native typedefs (C signatures)
// ───────────────────────────────
typedef _st_create_native = ffi.Pointer<ffi.Void> Function();
typedef _st_dispose_native = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _st_set_double_native =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double);

// ───────────────────────────────
// 2️⃣ Dart typedefs (Dart callable signatures)
// ───────────────────────────────
typedef _st_create_dart = ffi.Pointer<ffi.Void> Function();
typedef _st_dispose_dart = void Function(ffi.Pointer<ffi.Void>);
typedef _st_set_double_dart = void Function(ffi.Pointer<ffi.Void>, double);

// ───────────────────────────────
// 3️⃣ Bridge class
// ───────────────────────────────
class SoundTouchFFI {
  late ffi.DynamicLibrary _lib;
  late final _st_create_dart _create;
  late final _st_dispose_dart _dispose;
  late final _st_set_double_dart _setTempo;
  late final _st_set_double_dart _setPitch;

  ffi.Pointer<ffi.Void>? _handle;

  SoundTouchFFI() {
    // macOS / Windows 분기 처리
    final libName = Platform.isMacOS
        ? 'libsoundtouch_ffi.dylib'
        : Platform.isWindows
        ? 'soundtouch_ffi.dll'
        : 'libsoundtouch_ffi.so';

    _lib = ffi.DynamicLibrary.open(libName);

    _create = _lib.lookupFunction<_st_create_native, _st_create_dart>(
      'st_create',
    );
    _dispose = _lib.lookupFunction<_st_dispose_native, _st_dispose_dart>(
      'st_dispose',
    );
    _setTempo = _lib.lookupFunction<_st_set_double_native, _st_set_double_dart>(
      'st_set_tempo',
    );
    _setPitch = _lib.lookupFunction<_st_set_double_native, _st_set_double_dart>(
      'st_set_pitch_semitones',
    );

    _handle = _create();
  }

  void setTempo(double tempo) {
    if (_handle != null) _setTempo(_handle!, tempo);
  }

  void setPitch(double semi) {
    if (_handle != null) _setPitch(_handle!, semi);
  }

  void dispose() {
    if (_handle != null) {
      _dispose(_handle!);
      _handle = null;
    }
  }
}
