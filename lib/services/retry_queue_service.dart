// lib/services/retry_queue_service.dart
// 단순 재시도 큐 (메모리)
import 'dart:collection';
import 'dart:developer' as dev;
import '../services/lesson_service.dart';

enum PendingType { todayLessonPatch }

class PendingOp {
  final PendingType type;
  final String studentId;
  final Map<String, dynamic> payload; // patch 필드들(subject/memo/next_plan/youtube_url)
  int attempts;
  PendingOp({required this.type, required this.studentId, required this.payload, this.attempts = 0});
}

class RetryQueueService {
  final _q = Queue<PendingOp>();

  void enqueueTodayPatch(String studentId, Map<String, dynamic> patch) {
    _q.add(PendingOp(type: PendingType.todayLessonPatch, studentId: studentId, payload: patch));
    dev.log('Enqueued todayLessonPatch(${patch.keys.join(", ")}) for $studentId. q=${_q.length}', name: 'RetryQueue');
  }

  Future<(int success, int fail)> flushAll({LessonService? lessonService}) async {
    final svc = lessonService ?? LessonService();
    int ok = 0, fail = 0;
    while (_q.isNotEmpty) {
      final op = _q.removeFirst();
      try {
        await svc.patchToday(
          studentId: op.studentId,
          subject: op.payload['subject'],
          memo: op.payload['memo'],
          nextPlan: op.payload['next_plan'],
          youtubeUrl: op.payload['youtube_url'],
        );
        ok++;
      } catch (e) {
        op.attempts++;
        dev.log('Flush failed: $e', name: 'RetryQueue');
        if (op.attempts < 3) {
          _q.addLast(op);
        } else {
          fail++;
        }
      }
    }
    return (ok, fail);
  }

  int get pendingCount => _q.length;
}
