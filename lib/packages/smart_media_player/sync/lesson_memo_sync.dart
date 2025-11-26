// lib/packages/smart_media_player/sync/lesson_memo_sync.dart

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/lesson_service.dart';
import '../../../services/xsc_sync_service.dart';

typedef MemoChanged = void Function(String memo);

/// lessons.memo Realtime + 로컬 노트 버스 연결
class LessonMemoSync {
  LessonMemoSync._();
  static final LessonMemoSync instance = LessonMemoSync._();

  StreamSubscription<List<Map<String, dynamic>>>? _dbStreamSub;
  StreamSubscription<String>? _localBusSub;

  /// LWW 안정화를 위한 로컬 최신 메모
  String _lastMemo = '';

  // ======================================================
  // 초기 메모 1회 조회
  // ======================================================
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
    final memo = rows.isNotEmpty ? (rows.first['memo'] ?? '').toString() : '';
    _lastMemo = memo;
    return memo;
  }

  // ======================================================
  // DB → 앱 Realtime 구독 (Supabase stream)
  // ======================================================
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
        .order('updated_at')
        .listen((rows) {
          if (rows.isEmpty) return;

          // 정확한 매칭 row 추출
          final Map<String, dynamic>? hit = rows
              .cast<Map<String, dynamic>?>()
              .firstWhere(
                (r) =>
                    r != null &&
                    r['student_id'] == studentId &&
                    (r['date'] == dateISO ||
                        r['date']?.toString().startsWith(dateISO) == true),
                orElse: () => null,
              );

          if (hit == null) return;

          final memo = (hit['memo'] ?? '').toString();

          // 변경 없으면 이벤트 무시
          if (memo == _lastMemo) return;

          _lastMemo = memo;
          onMemoChanged(memo);
        });
  }

  // ======================================================
  // 로컬 노트 버스 ↔ 앱
  // ======================================================
  void subscribeLocalBus(MemoChanged onMemoChanged) {
    _localBusSub?.cancel();
    _localBusSub = XscSyncService.instance.notesStream.listen((memo) {
      if (memo == _lastMemo) return;

      _lastMemo = memo;
      onMemoChanged(memo);
    });
  }

  /// 화면에서 로컬 버스로 즉시 반영하고 싶을 때 호출
  void pushLocal(String memo) {
    _lastMemo = memo;
    XscSyncService.instance.pushNotes(memo);
  }

  // ======================================================
  // DB upsert
  // ======================================================
  Future<void> upsertMemo({
    required String studentId,
    required String dateISO,
    required String memo,
  }) async {
    _lastMemo = memo;
    await LessonService().upsert({
      'student_id': studentId,
      'date': dateISO,
      'memo': memo,
    });
  }

  // ======================================================
  // 자원 정리
  // ======================================================
  void dispose() {
    _dbStreamSub?.cancel();
    _dbStreamSub = null;
    _localBusSub?.cancel();
    _localBusSub = null;
  }
}
