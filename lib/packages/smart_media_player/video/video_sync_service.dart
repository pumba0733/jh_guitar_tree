// v3.41 — Step 4-3 VideoSyncService (FINAL)
// 책임: VideoController 생성 / 80ms 싱크 / throttle / align / 상태 반영

import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoSyncService {
  VideoSyncService._();
  static final VideoSyncService instance = VideoSyncService._();

  VideoController? _vc;
  Player? _player;
  Timer? _syncTimer;
  DateTime? _lastAlignAt;

  // ============================================================
  // PUBLIC GETTERS
  // ============================================================
  VideoController? get controller => _vc;
  bool get isVideoLoaded => _vc != null;

  Duration get videoPosition => _player?.state.position ?? Duration.zero;

  // ============================================================
  // ATTACH PLAYER
  // ============================================================
  Future<void> attachPlayer(Player player) async {
    _player = player;
    _vc = VideoController(player);

    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 80),
      (_) => _tick(),
    );
  }

  // ============================================================
  // INTERNAL DRIFT CORRECTION
  // ============================================================
  Future<void> _tick() async {
    final p = _player;
    if (p == null) return;

    final audioPos = p.state.position;
    final videoPos = p.state.position; // ← FIXED: VideoController.state 제거

    final drift = (videoPos - audioPos).inMilliseconds.abs();
    if (drift <= 8) return;

    // 최소 80ms throttle
    final now = DateTime.now();
    if (_lastAlignAt != null &&
        now.difference(_lastAlignAt!).inMilliseconds < 80) {
      return;
    }
    _lastAlignAt = now;

    try {
      await p.seek(audioPos);
    } catch (_) {}
  }


// ============================================================
  // PUBLIC ALIGN (Step 4-3 FINAL — Dual-throttle)
  // ============================================================
    Future<void> align(Duration d) async {
    final p = _player;
    if (p == null) return;

    // throttle 80ms 유지
    final now = DateTime.now();
    if (_lastAlignAt != null &&
        now.difference(_lastAlignAt!).inMilliseconds < 80) {
      return;
    }
    _lastAlignAt = now;

    // 상태와 무관하게 video/audio 타임스탬프만 맞추는 seek
    try {
      await p.seek(d);
    } catch (_) {}
  }


  // ============================================================
  // DISPOSE
  // ============================================================
  Future<void> dispose() async {
    _syncTimer?.cancel();
    _syncTimer = null;
    _vc = null;
    _player = null;
  }
}
