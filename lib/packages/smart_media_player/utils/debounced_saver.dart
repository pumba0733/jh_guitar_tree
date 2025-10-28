// lib/packages/smart_media_player/utils/debounced_saver.dart
// v1.1.0 — dispose 가드 추가(재발 방지)

import 'dart:async';
import 'package:flutter/material.dart';
import '../../../ui/components/save_status_indicator.dart';

typedef SaveTask = Future<void> Function();

class DebouncedSaver with ChangeNotifier {
  DebouncedSaver({this.delay = const Duration(milliseconds: 800)});

  final Duration delay;

  Timer? _timer;
  SaveStatus _status = SaveStatus.idle;
  DateTime? _lastSavedAt;
  int _pendingRetryCount = 0;
  bool _disposed = false; // ✅ 추가

  SaveStatus get status => _status;
  DateTime? get lastSavedAt => _lastSavedAt;
  int get pendingRetryCount => _pendingRetryCount;

  // ✅ 안전 notify
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _setStatus(SaveStatus s) {
    if (_status == s) return;
    _status = s;
    _safeNotify(); // ✅ 변경
  }

  /// Schedule a save with debounce.
  void schedule(SaveTask task) {
    if (_disposed) return; // ✅ dispose 이후 no-op
    _timer?.cancel();
    _setStatus(SaveStatus.saving);
    _timer = Timer(delay, () async {
      if (_disposed) return; // ✅ 타이머 만료 시점에도 가드
      try {
        await task();
        _pendingRetryCount = 0;
        _lastSavedAt = DateTime.now();
        _setStatus(SaveStatus.saved);
      } catch (_) {
        _pendingRetryCount += 1;
        _setStatus(SaveStatus.failed);
      }
    });
  }

  /// Force immediate save (no debounce).
  Future<void> flush(SaveTask task) async {
    if (_disposed) return; // ✅ dispose 이후 no-op
    _timer?.cancel();
    _setStatus(SaveStatus.saving);
    try {
      await task();
      _pendingRetryCount = 0;
      _lastSavedAt = DateTime.now();
      _setStatus(SaveStatus.saved);
    } catch (_) {
      _pendingRetryCount += 1;
      _setStatus(SaveStatus.failed);
    }
  }

  @override
  void dispose() {
    _disposed = true; // ✅ 먼저 플래그 ON
    _timer?.cancel(); // ✅ 타이머 제거
    _timer = null;
    super.dispose();
  }
}
