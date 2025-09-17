// lib/supabase/supabase_tables.dart
// v1.44.1 | 테이블/뷰/버킷 상수 보강 (lesson_resource_links 추가)

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
  // 실제 테이블(권장 네이밍): lesson_resource_links
  static const String lessonResourceLinks = 'lesson_resource_links';
  // 호환/뷰 이름: lesson_links
  static const String lessonLinks = 'lesson_links';
}

class SupabaseViews {
  static const String logDailyCounts = 'log_daily_counts';
}

class SupabaseBuckets {
  static const String curriculumFiles = 'curriculum';
  static const String lessonAttachments = 'lesson_attachments';
}
