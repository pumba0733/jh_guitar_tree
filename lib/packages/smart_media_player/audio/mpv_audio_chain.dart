// v2.2.0 — feature-probing: scaletempo2→scaletempo 폴백, lavfi(피치) 불가 시 템포만 적용

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:media_kit/media_kit.dart';
import 'audio_chain_utils.dart';

class MpvAudioChain {
  MpvAudioChain._();
  static final MpvAudioChain I = MpvAudioChain._();

  Future<void> apply({
    required Player player,
    required bool isVideo,
    required bool muted,
    required int volumePercent,
    required double speed,
    required int pitchSemi,
  }) async {
    final dynamic mpv = player.platform;

    final spd = normalizeSpeed(speed);
    final semi = normalizePitchSemi(pitchSemi);
    final k = math.pow(2.0, semi / 12.0).toDouble();
    final vol = splitVolume150(volumePercent);

    // 기본 장치/볼륨/뮤트
    try {
      await mpv?.setProperty('vid', isVideo ? 'auto' : 'no');
      await mpv?.setProperty('audio-exclusive', 'no');
      await mpv?.setProperty('audio-device', 'auto');
      await mpv?.setProperty('ao', Platform.isMacOS ? 'coreaudio' : 'wasapi');
      await mpv?.setProperty(
        'mute',
        (muted || vol.mpvVolume == 0) ? 'yes' : 'no',
      );
      await mpv?.setProperty('volume', '${vol.mpvVolume.clamp(0, 100)}');
    } catch (_) {}

    // rate는 1.0 고정 (템포는 필터에서만)
    try {
      if (player.state.rate != 1.0) {
        await player.setRate(1.0);
      }
    } catch (_) {}

    // 샘플레이트 읽기 (표현식 대신 실수치 사용)
    int sr = 48000;
    try {
      final got = await mpv?.getProperty('audio-params/samplerate');
      final n = int.tryParse('$got');
      if (n != null && n >= 8000) sr = n;
    } catch (_) {}

    // ---- 1) 템포 필터 지원 탐지: scaletempo2 → scaletempo 폴백 ----
    String? tempoFilterName;
    try {
      final test = 'scaletempo2=scale=${spd.toStringAsFixed(6)}';
      await mpv?.setProperty('af', test);
      final after = await mpv?.getProperty('af');
      if ('$after'.contains('scaletempo2')) {
        tempoFilterName = 'scaletempo2';
      }
    } catch (_) {}

    if (tempoFilterName == null) {
      try {
        final test = 'scaletempo=scale=${spd.toStringAsFixed(6)}';
        await mpv?.setProperty('af', test);
        final after = await mpv?.getProperty('af');
        if ('$after'.contains('scaletempo')) {
          tempoFilterName = 'scaletempo';
        }
      } catch (_) {}
    }

    // ---- 2) 피치(lavfi) 가능 여부 점검: asetrate+aresample ----
    bool pitchAvailable = false;
    if (semi != 0) {
      try {
        final t = (sr * k).round().clamp(8000, 384000);
        final test = 'asetrate=$t,aresample=$sr';
        await mpv?.setProperty('af', test);
        final after = await mpv?.getProperty('af');
        if ('$after'.contains('asetrate') && '$after'.contains('aresample')) {
          pitchAvailable = true;
        }
      } catch (_) {}
    }

    // ---- 3) 최종 체인 조립 & 적용 ----
    final chain = <String>[];

    if (semi != 0 && pitchAvailable) {
      final t = (sr * k).round().clamp(8000, 384000);
      chain.add('asetrate=$t');
      chain.add('aresample=$sr');
    }

    if (tempoFilterName != null) {
      final scale = (semi != 0 && pitchAvailable) ? (spd / k) : spd;
      chain.add('$tempoFilterName=scale=${scale.toStringAsFixed(6)}');
    }

    if (vol.postAmpDb > 0.0001) {
      chain.add('volume=${vol.postAmpDb.toStringAsFixed(2)}dB');
    }

    final afStr = chain.isEmpty ? 'none' : chain.join(',');
    try {
      await mpv?.setProperty('af', afStr);
    } catch (_) {
      // 마지막 폴백: 템포만(가능하다면) + 볼륨
      final fb = <String>[];
      if (tempoFilterName != null) {
        fb.add('$tempoFilterName=scale=${spd.toStringAsFixed(6)}');
      }
      if (vol.postAmpDb > 0.0001) {
        fb.add('volume=${vol.postAmpDb.toStringAsFixed(2)}dB');
      }
      try {
        await mpv?.setProperty('af', fb.isEmpty ? 'none' : fb.join(','));
      } catch (_) {}
    }
  }
}
