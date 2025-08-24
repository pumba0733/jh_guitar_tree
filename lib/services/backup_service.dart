// lib/services/backup_service.dart
// JSON 백업/복원 (데스크탑 전용 권장) — 실제 파일 저장/열기는 UI에서 분기
import '../services/lesson_service.dart';
import '../services/summary_service.dart';

class BackupService {
  final LessonService _lesson = LessonService();
  final SummaryService _summary = SummaryService();

  Future<Map<String, dynamic>> buildStudentBackupJson(String studentId) async {
    final lessons = await _lesson.listByStudent(studentId, limit: 1000);
    final summaries = await _summary.listByStudent(studentId, limit: 1000);
    return {
      'version': 'v1.20',
      'student_id': studentId,
      'lessons': lessons.map((e) => e.toMap()).toList(),
      'summaries': summaries.map((e) => {
        'id': e.id,
        'student_id': e.studentId,
        'type': e.type,
        'period_start': e.periodStart?.toIso8601String(),
        'period_end': e.periodEnd?.toIso8601String(),
        'keywords': e.keywords,
        'selected_lesson_ids': e.selectedLessonIds,
        'result_student': e.resultStudent,
        'result_parent': e.resultParent,
        'result_blog': e.resultBlog,
        'result_teacher': e.resultTeacher,
        'visible_to': e.visibleTo,
        'created_at': e.createdAt?.toIso8601String(),
      }).toList(),
    };
  }

  // 간단 복원: lessons/summaries upsert
  // 운영 시 중복 정책/권한 고려 필요
}
