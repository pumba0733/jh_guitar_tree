// lib/packages/smart_media_player/utils/log.dart
// v1.0.0 — Tiny logger with tag & throttle.

import 'dart:async';

typedef _Stamp = DateTime;

class Log {
  Log._();
  static final Log I = Log._();

  final _last = <String, _Stamp>{};

  /// Print with tag like: [SMP] message
  void d(String tag, String message) {
    // ignore: avoid_print
    print('[$tag] $message');
  }

  /// Throttled log: skip if called again within [interval].
  bool dThrottled(
    String tag,
    String key,
    String message, {
    Duration interval = const Duration(seconds: 2),
  }) {
    final now = DateTime.now();
    final last = _last['$tag::$key'];
    if (last != null && now.difference(last) < interval) {
      return false;
    }
    _last['$tag::$key'] = now;
    d(tag, message);
    return true;
  }

  /// Catch & log errors (returns null if throws).
  Future<T?> guard<T>(
    String tag,
    String action,
    Future<T> Function() run,
  ) async {
    try {
      return await run();
    } catch (e, st) {
      d(tag, 'ERROR <$action>: $e\n$st');
      return null;
    }
  }
}
