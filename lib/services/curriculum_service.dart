// lib/services/curriculum_service.dart
// v1.21.2 | 커리큘럼 읽기/배정 최소 서비스
import 'package:supabase_flutter/supabase_flutter.dart';

class CurriculumService {
  final SupabaseClient _c = Supabase.instance.client;

  Future<List<Map<String, dynamic>>> listNodes() async {
    final data = await _c.from('curriculum_nodes').select().order('created_at');
    return (data as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    // 테이블이 없으면 호출 측에서 try/catch로 안내하세요.
  }

  Future<List<Map<String, dynamic>>> listAssignmentsByStudent(
    String studentId,
  ) async {
    final data = await _c
        .from('curriculum_assignments')
        .select()
        .eq('student_id', studentId);
    return (data as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> assignNodeToStudent({
    required String studentId,
    required String nodeId,
    List<String>? path,
    String? filePath,
  }) async {
    await _c.from('curriculum_assignments').upsert({
      'student_id': studentId,
      'curriculum_node_id': nodeId,
      if (path != null) 'path': path,
      if (filePath != null) 'file_path': filePath,
    });
  }
}
