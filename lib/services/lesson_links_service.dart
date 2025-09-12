// lib/services/lesson_links_service.dart
// v1.44.0 | 오늘 레슨 링크 서비스 (RPC + 조회 유틸 보강)
// - sendNodeToTodayLesson / sendResourceToTodayLesson : 기존 bool 유지
// - *Id() 버전 추가: 생성된 link UUID 반환
// - listByLesson(), listTodayByStudent() 유틸 추가
// - ensure=false 기본(생성 없이 조회), 필요 시 ensure=true로 오늘레슨 보장

import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/resource.dart';

class LessonLinksService {
  final SupabaseClient _c = Supabase.instance.client;

  // ---------- 내부 헬퍼 ----------
  Future<String?> _rpcString(String fn, Map<String, dynamic> params) async {
    try {
      final res = await _c.rpc(fn, params: params);
      if (res == null) return null;
      // Supabase rpc가 UUID 텍스트를 바로 반환하면 dynamic -> String 으로 캐스팅
      return res.toString();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _findTodayLessonId(String studentId) async {
    try {
      // 생성 없이 '오늘' 레슨 찾기
      final today = DateTime.now();
      final yyyy = today.year.toString().padLeft(4, '0');
      final mm = today.month.toString().padLeft(2, '0');
      final dd = today.day.toString().padLeft(2, '0');
      final d = '$yyyy-$mm-$dd';

      final rows = await _c
          .from('lessons')
          .select('id')
          .eq('student_id', studentId)
          .eq('date', d)
          .limit(1);

      if (rows.isEmpty) return null;
      return (rows.first['id'] ?? '').toString();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _ensureTodayLessonId(String studentId) async {
    // 서버에서 생성까지 보장
    return _rpcString('ensure_today_lesson', {'p_student_id': studentId});
    // (권한/RLS로 거부될 수 있음 → null)
  }

  // ---------- 보냄: 노드 ----------
  /// 커리큘럼 노드를 '오늘 레슨'에 링크로 추가 (ID 반환)
  Future<String?> sendNodeToTodayLessonId({
    required String studentId,
    required String nodeId,
  }) {
    return _rpcString('link_node_to_today_lesson', {
      'p_student_id': studentId,
      'p_node_id': nodeId,
    });
  }

  /// 커리큘럼 노드를 '오늘 레슨'에 링크로 추가 (성공 여부)
  Future<bool> sendNodeToTodayLesson({
    required String studentId,
    required String nodeId,
  }) async {
    final id = await sendNodeToTodayLessonId(
      studentId: studentId,
      nodeId: nodeId,
    );
    return id != null;
  }

  // ---------- 보냄: 리소스 ----------
  /// 리소스를 '오늘 레슨'에 링크로 추가 (ID 반환)
  Future<String?> sendResourceToTodayLessonId({
    required String studentId,
    required ResourceFile resource,
  }) {
    return _rpcString('link_resource_to_today_lesson', {
      'p_student_id': studentId,
      'p_bucket': resource.storageBucket,
      'p_path': resource.storagePath,
      'p_filename': resource.filename,
      'p_title': resource.title,
    });
  }

  /// 리소스를 '오늘 레슨'에 링크로 추가 (성공 여부)
  Future<bool> sendResourceToTodayLesson({
    required String studentId,
    required ResourceFile resource,
  }) async {
    final id = await sendResourceToTodayLessonId(
      studentId: studentId,
      resource: resource,
    );
    return id != null;
  }

  // ---------- 조회 ----------
  /// 특정 레슨의 링크 목록(최신순)
  Future<List<Map<String, dynamic>>> listByLesson(String lessonId) async {
    try {
      final rows = await _c
          .from('lesson_links')
          .select()
          .eq('lesson_id', lessonId)
          .order('created_at', ascending: false);
      final list = (rows as List<dynamic>? ?? const []);
      return list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// '오늘 레슨'의 링크 목록
  /// - ensure=true: 없으면 서버에서 오늘 레슨을 생성한 뒤 조회
  Future<List<Map<String, dynamic>>> listTodayByStudent(
    String studentId, {
    bool ensure = false,
  }) async {
    String? lessonId = await _findTodayLessonId(studentId);
    if (lessonId == null && ensure) {
      lessonId = await _ensureTodayLessonId(studentId);
    }
    if (lessonId == null) return const [];
    return listByLesson(lessonId);
  }
}
