// lib/supabase/supabase_tables.dart
// v1.44.0 | 테이블/버킷 상수 보강

class SupabaseTables {
  static const String teachers = 'teachers';
  static const String students = 'students';
  static const String lessons = 'lessons';
  static const String summaries = 'summaries';
  static const String feedbackKeywords = 'feedback_keywords';
  static const String logs = 'logs';

  static const String curriculumNodes = 'curriculum_nodes';
  static const String curriculumAssignments = 'curriculum_assignments';

  // 보강
  static const String resources = 'resources';
  static const String curriculumProgress = 'curriculum_progress';
  static const String lessonLinks = 'lesson_links';
}

class SupabaseViews {
  static const String logDailyCounts = 'log_daily_counts';
}

class SupabaseBuckets {
  static const String curriculumFiles =
      'curriculum'; // ← 'curriculum_files' → 'curriculum'
  static const lessonAttachments = 'lesson_attachments';
}
