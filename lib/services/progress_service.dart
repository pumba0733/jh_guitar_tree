// lib/services/progress_service.dart
// v1.44.0 | 학생 진도 토글/집계 – 테이블 존재 감지(42P01) 방식으로 통일
// - information_schema 의존 제거(환경차 이슈 회피)
// - select().limit(1) 테스트 + 42P01 캐치
// - 나머지 API 동일

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProgressService {
  final SupabaseClient _c = Supabase.instance.client;
  static const _table = 'curriculum_progress';

  Future<bool> _tableExists() async {
    try {
      await _c.from(_table).select('student_id').limit(1);
      return true;
    } catch (e) {
      final s = e.toString();
      // 42P01: undefined_table
      if (s.contains('42P01') ||
          (s.contains('relation') && s.contains('does not exist'))) {
        return false;
      }
      // 기타 오류는 일시 오류로 간주하여 존재한다고 보고 동작(상위에서 재시도/메시지 처리)
      return true;
    }
  }

  /// 토글: true면 완료, false면 미완료
  Future<bool> toggle({
    required String studentId,
    required String nodeId,
  }) async {
    if (!await _tableExists()) return false; // 안전 no-op

    final Map<String, dynamic>? existing = await _c
        .from(_table)
        .select('done')
        .eq('student_id', studentId)
        .eq('curriculum_node_id', nodeId)
        .maybeSingle()
        .then((v) => v == null ? null : Map<String, dynamic>.from(v as Map));

    final nowDone = !((existing?['done'] ?? false) == true);

    if (existing == null) {
      await _c.from(_table).insert({
        'student_id': studentId,
        'curriculum_node_id': nodeId,
        'done': nowDone,
      });
    } else {
      await _c
          .from(_table)
          .update({'done': nowDone})
          .eq('student_id', studentId)
          .eq('curriculum_node_id', nodeId);
    }
    return nowDone;
  }

  /// 학생의 노드별 완료 상태 일괄 조회
  Future<Map<String, bool>> mapByStudent(String studentId) async {
    if (!await _tableExists()) return {};
    final List rows = await _c
        .from(_table)
        .select('curriculum_node_id,done,updated_at')
        .eq('student_id', studentId);

    final map = <String, bool>{};
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      map[m['curriculum_node_id'].toString()] = (m['done'] ?? false) == true;
    }
    return map;
  }

  /// 완료 개수 / 총 배정 개수 집계 (해당 테이블 기준)
  Future<(int done, int total)> summary(String studentId) async {
    if (!await _tableExists()) return (0, 0);

    final List totalRows = await _c
        .from(_table)
        .select('curriculum_node_id')
        .eq('student_id', studentId);

    final List doneRows = await _c
        .from(_table)
        .select('curriculum_node_id')
        .eq('student_id', studentId)
        .eq('done', true);

    final int total = totalRows.length;
    final int done = doneRows.length;
    return (done, total);
  }
}
