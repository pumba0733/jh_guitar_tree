// lib/packages/smart_media_player/sync/lesson_memo_sync.dart
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/lesson_service.dart';
import '../../../services/xsc_sync_service.dart';

typedef MemoChanged = void Function(String memo);

/// lessons.memo Realtime + 로컬 버스 연결
class LessonMemoSync {
  LessonMemoSync._();
  static final LessonMemoSync instance = LessonMemoSync._();

  StreamSubscription<List<Map<String, dynamic>>>? _dbStreamSub;
  StreamSubscription<String>? _localBusSub;

  /// 초기 메모 1회 조회
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

  /// DB → 앱 Realtime 구독 (Supabase stream)
  void subscribeRealtime({
    required String studentId,
    required String dateISO, // yyyy-mm-dd
    required MemoChanged onMemoChanged,
  }) {
    _dbStreamSub?.cancel();

    final supa = Supabase.instance.client;
    _dbStreamSub = supa
        .from('lessons')
        .stream(primaryKey: ['id'])
        .order('updated_at') // 정렬만 적용 (필터는 아래에서)
        .listen((rows) {
          final hit = rows.firstWhere(
            (r) => r['student_id'] == studentId && r['date'] == dateISO,
            orElse: () => const {},
          );
          final memo = (hit['memo'] ?? '').toString();
          onMemoChanged(memo);
        });
  }

  /// 로컬 노트 버스 ↔ 앱
  void subscribeLocalBus(MemoChanged onMemoChanged) {
    _localBusSub?.cancel();
    _localBusSub = XscSyncService.instance.notesStream.listen(onMemoChanged);
  }

  /// 화면에서 로컬 버스로 즉시 반영하고 싶을 때 호출
  void pushLocal(String memo) {
    XscSyncService.instance.pushNotes(memo);
  }

  /// DB upsert
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
    _dbStreamSub?.cancel();
    _dbStreamSub = null;
    _localBusSub?.cancel();
    _localBusSub = null;
  }
}
