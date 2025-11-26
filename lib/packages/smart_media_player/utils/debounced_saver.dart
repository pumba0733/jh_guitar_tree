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
  bool _disposed = false;

  // 🔥 6-D 추가: 재진입 방지 락
  bool _saving = false; // flush/schedule 실제 실행 중
  bool _pendingFlush = false; // flush 중 다시 flush 요구될 때 1번만 재실행


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
    if (_disposed) return;

    // 🔥 이미 saving 중이면 “예약만” 하고 빠진다.
    if (_saving) {
      _pendingFlush = true;
      return;
    }

    _timer?.cancel();
    _setStatus(SaveStatus.saving);

    _timer = Timer(delay, () async {
      if (_disposed) return;
      if (_saving) {
        _pendingFlush = true;
        return;
      }

      _saving = true;
      try {
        await task();
        _pendingRetryCount = 0;
        _lastSavedAt = DateTime.now();
        _setStatus(SaveStatus.saved);
      } catch (_) {
        _pendingRetryCount += 1;
        _setStatus(SaveStatus.failed);
      } finally {
        _saving = false;
        if (_pendingFlush && !_disposed) {
          _pendingFlush = false;
          unawaited(flush(task));
        }
      }
    });
  }


  /// Force immediate save (no debounce).
  Future<void> flush(SaveTask task) async {
    if (_disposed) return;

    // 🔥 saving 중이면 중복 flush 금지 → 예약만
    if (_saving) {
      _pendingFlush = true;
      return;
    }

    _timer?.cancel();
    _setStatus(SaveStatus.saving);

    _saving = true;
    try {
      await task();
      _pendingRetryCount = 0;
      _lastSavedAt = DateTime.now();
      _setStatus(SaveStatus.saved);
    } catch (_) {
      _pendingRetryCount += 1;
      _setStatus(SaveStatus.failed);
    } finally {
      _saving = false;

      // 🔥 dispose 되지 않았고 pendingFlush 있으면 1회 실행
      if (_pendingFlush && !_disposed) {
        _pendingFlush = false;
        unawaited(flush(task));
      }
    }
  }


  @override
  void dispose() {
    _disposed = true;
    _pendingFlush = false; // 🔥 dispose 중 flush 예약 제거
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

}
