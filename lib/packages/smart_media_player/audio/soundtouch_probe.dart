import 'dart:ffi';
import 'package:flutter/foundation.dart';

class SoundTouchProbe {
  static bool? _cached;

  static Future<bool> canLoad({bool force = false}) async {
    if (_cached != null && !force) return _cached!;
    try {
      // macOS 번들 내 Frameworks 폴더에 복사된 이름과 동일해야 함
      DynamicLibrary.open('libsoundtouch.dylib');
      debugPrint('[SMP] SoundTouch dylib load: OK ✅');
      return _cached = true;
    } catch (e, st) {
      debugPrint('[SMP] SoundTouch dylib load: FAIL ❌  $e');
      debugPrint('$st');
      return _cached = false;
    }
  }

  static bool? get cached => _cached;
}
