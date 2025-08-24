// lib/models/summary.dart
class Summary {
  final String id;
  final String studentId;
  final String? teacherId;
  final String type; // '기간별' | '키워드'
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final List<String> keywords;
  final List<String> selectedLessonIds;
  final Map<String, dynamic>? studentInfo;
  final String? resultStudent;
  final String? resultParent;
  final String? resultBlog;
  final String? resultTeacher;
  final List<String> visibleTo;
  final DateTime? createdAt;

  const Summary({
    required this.id,
    required this.studentId,
    required this.type,
    this.teacherId,
    this.periodStart,
    this.periodEnd,
    this.keywords = const [],
    this.selectedLessonIds = const [],
    this.studentInfo,
    this.resultStudent,
    this.resultParent,
    this.resultBlog,
    this.resultTeacher,
    this.visibleTo = const ['teacher','admin'],
    this.createdAt,
  });

  factory Summary.fromMap(Map<String, dynamic> m) {
    return Summary(
      id: m['id'] as String,
      studentId: m['student_id'] as String,
      teacherId: m['teacher_id'] as String?,
      type: (m['type'] as String?) ?? '기간별',
      periodStart: m['period_start'] != null
          ? DateTime.tryParse('${m['period_start']}')
          : null,
      periodEnd: m['period_end'] != null
          ? DateTime.tryParse('${m['period_end']}')
          : null,
      keywords: (m['keywords'] as List?)?.map((e) => '$e').toList() ?? const [],
      selectedLessonIds: (m['selected_lesson_ids'] as List?)
          ?.map((e) => '$e').toList() ?? const [],
      studentInfo: m['student_info'] as Map<String, dynamic>?,
      resultStudent: m['result_student'] as String?,
      resultParent: m['result_parent'] as String?,
      resultBlog: m['result_blog'] as String?,
      resultTeacher: m['result_teacher'] as String?,
      visibleTo:
          (m['visible_to'] as List?)?.map((e) => '$e').toList() ?? const ['teacher','admin'],
      createdAt: m['created_at'] != null
          ? DateTime.tryParse('${m['created_at']}')
          : null,
    );
  }
}
