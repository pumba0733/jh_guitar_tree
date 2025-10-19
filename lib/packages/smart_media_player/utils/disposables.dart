// lib/packages/smart_media_player/utils/disposables.dart
// v1.0.0 — Disposer bag for StreamSubscription/Timer/futures

import 'dart:async';

/// Small helper to collect disposables (subscriptions, timers).
class Disposables {
  final _subs = <StreamSubscription>[];
  final _timers = <Timer>[];

  T addSub<T extends StreamSubscription>(T sub) {
    _subs.add(sub);
    return sub;
  }

  T addTimer<T extends Timer>(T t) {
    _timers.add(t);
    return t;
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    for (final t in _timers) {
      try {
        t.cancel();
      } catch (_) {}
    }
    _timers.clear();
  }
}
