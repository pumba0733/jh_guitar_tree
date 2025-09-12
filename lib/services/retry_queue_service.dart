// lib/services/retry_queue_service.dart
import 'dart:async';
import 'dart:developer' as dev; // ✅ 로깅 프레임워크 사용
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RetryTask {
  final String id;
  final String kind;
  final Map<String, dynamic> payload;
  final int retries;
  final DateTime createdAt;

  RetryTask({
    required this.id,
    required this.kind,
    required this.payload,
    this.retries = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  RetryTask copyWith({int? retries}) => RetryTask(
    id: id,
    kind: kind,
    payload: payload,
    retries: retries ?? this.retries,
    createdAt: createdAt,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'kind': kind,
    'payload': payload,
    'retries': retries,
    'createdAt': createdAt.toIso8601String(),
  };

  static RetryTask fromMap(Map<String, dynamic> m) => RetryTask(
    id: m['id'] as String,
    kind: m['kind'] as String,
    payload: Map<String, dynamic>.from(m['payload'] as Map),
    retries: (m['retries'] as num?)?.toInt() ?? 0,
    createdAt:
        DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}

class RetryQueueService {
  RetryQueueService._internal();
  static final RetryQueueService _i = RetryQueueService._internal();
  factory RetryQueueService() => _i;

  Timer? _timer;
  Box? _cachedBox;

  Future<Box> _box() async {
    if (_cachedBox != null && _cachedBox!.isOpen) return _cachedBox!;
    _cachedBox = await Hive.openBox('retry_queue_box');
    return _cachedBox!;
  }

  Future<int> get pendingCount async {
    final b = await _box();
    return b.length;
  }

  Future<void> enqueueTodayPatch({
    required String studentId,
    required DateTime date,
    required Map<String, dynamic> patch,
  }) async {
    final keyDate = date.toIso8601String().split('T').first;
    final id = 'lesson:$studentId:$keyDate';
    final row = {'student_id': studentId, 'date': keyDate, ...patch};
    final task = RetryTask(
      id: id,
      kind: 'lesson_upsert',
      payload: {'row': row},
    );
    await enqueue(task);
  }

  Future<void> enqueue(RetryTask task) async {
    final b = await _box();
    await b.put(task.id, task.toMap());
  }

  Future<void> remove(String id) async {
    final b = await _box();
    await b.delete(id);
  }

  Future<({int success, int failure})> flushAll() async {
    final b = await _box();
    final client = Supabase.instance.client;

    int ok = 0, fail = 0;
    final keys = b.keys.toList();
    for (final k in keys) {
      final raw = b.get(k);
      if (raw == null) continue;
      final task = RetryTask.fromMap(Map<String, dynamic>.from(raw as Map));

      final success = await _processTask(client, task);
      if (success) {
        ok++;
        await b.delete(k);
      } else {
        final next = task.copyWith(retries: task.retries + 1);
        if (next.retries >= 5) {
          await b.delete(k);
        } else {
          await b.put(k, next.toMap());
        }
        fail++;
      }
    }
    return (success: ok, failure: fail);
  }

  Future<bool> _processTask(SupabaseClient client, RetryTask task) async {
    try {
      switch (task.kind) {
        case 'lesson_upsert':
          final row = Map<String, dynamic>.from(task.payload['row'] as Map);
          await client.from('lessons').upsert(row);
          return true;
        case 'summary_upsert':
          final row = Map<String, dynamic>.from(task.payload['row'] as Map);
          await client.from('summaries').upsert(row);
          return true;
        default:
          return false;
      }
    } catch (e, st) {
      // ✅ print 대체
      dev.log(
        'RetryQueue error',
        name: 'RetryQueueService',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  void start({Duration interval = const Duration(seconds: 10)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) async {
      try {
        await flushAll();
      } catch (e, st) {
        // ✅ print 대체
        dev.log(
          'RetryQueue flush error',
          name: 'RetryQueueService',
          error: e,
          stackTrace: st,
        );
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
