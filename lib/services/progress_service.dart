// lib/services/progress_service.dart
// v1.43.1 | 학생 진도 토글/집계 (curriculum_progress 스키마 반영)
// - 테이블명: curriculum_progress
// - 컬럼명: done(boolean), updated_at
// - information_schema로 존재 여부 확인 → 없으면 안전 no-op
// - length 기반 집계(별도 count 의존 X)

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProgressService {
  final SupabaseClient _c = Supabase.instance.client;
  static const _table = 'curriculum_progress';

  Future<bool> _tableExists() async {
    try {
      final List rows = await _c
          .from('information_schema.tables')
          .select('table_name')
          .eq('table_schema', 'public')
          .eq('table_name', _table);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
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
