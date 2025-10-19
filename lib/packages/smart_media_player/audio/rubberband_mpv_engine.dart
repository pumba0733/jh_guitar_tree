// lib/packages/smart_media_player/audio/rubberband_mpv_engine.dart
// v1.0.1 — Fix: use dynamic platform to access mpv setProperty safely.

import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'audio_chain_utils.dart';

class RubberbandMpvEngine {
  RubberbandMpvEngine._();
  static final RubberbandMpvEngine I = RubberbandMpvEngine._();

  Future<void> apply({
    required Player player,
    required bool isVideo,
    required bool muted,
    required int volumePercent, // 0..150
    required double speed, // 0.5..1.5
    required int pitchSemi, // -7..+7
  }) async {
    // IMPORTANT: use dynamic to bypass static check — mpv exposes setProperty at runtime.
    final dynamic plat = player.platform;

    // 1) Basic device/mute/volume
    final volSplit = splitVolume150(volumePercent);
    try {
      // These properties exist on mpv; ignore errors on other backends.
      await plat?.setProperty('ao', 'coreaudio');
      await plat?.setProperty('audio-exclusive', 'no');
      await plat?.setProperty('audio-device', 'auto');
      await plat?.setProperty('vid', isVideo ? 'auto' : 'no');

      await plat?.setProperty(
        'mute',
        (muted || volSplit.mpvVolume == 0) ? 'yes' : 'no',
      );
      await plat?.setProperty('volume', '${volSplit.mpvVolume.clamp(0, 100)}');
    } catch (_) {
      // no-op: non-mpv backend or unsupported property
    }

    // 2) Speed (tempo)
    await player.setRate(normalizeSpeed(speed));

    // 3) Build AF chain (rubberband pitch + post volume gain)
    final af = <String>[];

    final semi = normalizePitchSemi(pitchSemi);
    final ratio = semitoneToRatio(semi);
    if (semi != 0) {
      af.add(
        'rubberband='
        'pitch-scale=${ratio.toStringAsFixed(6)}'
        ':transients=smooth'
        ':formant=preserve',
      );
    }

    if (volSplit.postAmpDb > 0.0001) {
      af.add('volume=${volSplit.postAmpDb.toStringAsFixed(2)}dB');
    }

    final afStr = af.join(',');
    try {
      await plat?.setProperty('af', afStr.isEmpty ? 'none' : afStr);
    } catch (_) {
      // non-mpv backend: ignore
    }
  }
}
