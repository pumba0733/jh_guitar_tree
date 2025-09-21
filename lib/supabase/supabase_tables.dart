// lib/supabase/supabase_tables.dart
// v1.65 | lesson_attachments 테이블/버킷 상수 추가

class SupabaseTables {
  static const String teachers = 'teachers';
  static const String students = 'students';
  static const String lessons = 'lessons';
  static const String summaries = 'summaries';
  static const String feedbackKeywords = 'feedback_keywords';
  static const String logs = 'logs';

  static const String curriculumNodes = 'curriculum_nodes';
  static const String curriculumAssignments = 'curriculum_assignments';
  static const String curriculumProgress = 'curriculum_progress';

  // 리소스/링크
  static const String resources = 'resources';
  static const String lessonResourceLinks = 'lesson_resource_links';
  static const String lessonLinks = 'lesson_links';

  // ✅ 추가: 첨부 실테이블
  static const String lessonAttachments = 'lesson_attachments';
}

class SupabaseViews {
  static const String logDailyCounts = 'log_daily_counts';
}

class SupabaseBuckets {
  static const String curriculumFiles = 'curriculum';
  static const String lessonAttachments = 'lesson_attachments';
  // ✅ 추가: 학생별 XSC 버킷
  static const String studentXsc = 'student_xsc';
}
