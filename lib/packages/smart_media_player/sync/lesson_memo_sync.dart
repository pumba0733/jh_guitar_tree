import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/lesson_service.dart';
import '../../../services/xsc_sync_service.dart';


typedef MemoChanged = void Function(String memo);

/// lessons.memo Realtime + 로컬 버스 연결
class LessonMemoSync {
  LessonMemoSync._();
  static final LessonMemoSync instance = LessonMemoSync._();

  RealtimeChannel? _chan;
  StreamSubscription<String>? _localBusSub;

  Future<String> fetchInitialMemo({
    required String studentId,
    required DateTime day,
  }) async {
    final d0 = DateTime(day.year, day.month, day.day);
    final rows = await LessonService().listByStudent(
      studentId,
      from: d0,
      to: d0,
      limit: 1,
    );
    return rows.isNotEmpty ? (rows.first['memo'] ?? '').toString() : '';
  }

  /// DB → 앱 Realtime 구독
  void subscribeRealtime({
    required String studentId,
    required String dateISO, // yyyy-mm-dd
    required MemoChanged onMemoChanged,
  }) {
    _chan?.unsubscribe();
    final supa = Supabase.instance.client;
    _chan = supa
        .channel('lessons-memo-$studentId-$dateISO')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'lessons',
          callback: (payload) {
            final m = (payload.newRecord['memo'] ?? '').toString();
            onMemoChanged(m);
          },
        )
        .subscribe();
  }

  /// 로컬 노트 버스 ↔ 앱
  void subscribeLocalBus(MemoChanged onMemoChanged) {
    _localBusSub?.cancel();
    _localBusSub = XscSyncService.instance.notesStream.listen((text) {
      onMemoChanged(text);
    });
  }

  Future<void> upsertMemo({
    required String studentId,
    required String dateISO,
    required String memo,
  }) async {
    await LessonService().upsert({
      'student_id': studentId,
      'date': dateISO,
      'memo': memo,
    });
  }

  void dispose() {
    _chan?.unsubscribe();
    _chan = null;
    _localBusSub?.cancel();
    _localBusSub = null;
  }
}
