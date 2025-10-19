// lib/packages/smart_media_player/utils/debounced_saver.dart
// v1.0.0 — Simple debounced save orchestrator with status exposure.

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

  SaveStatus get status => _status;
  DateTime? get lastSavedAt => _lastSavedAt;
  int get pendingRetryCount => _pendingRetryCount;

  void _setStatus(SaveStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  /// Schedule a save with debounce.
  void schedule(SaveTask task) {
    _timer?.cancel();
    _setStatus(SaveStatus.saving);
    _timer = Timer(delay, () async {
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
    _timer?.cancel();
    super.dispose();
  }
}
