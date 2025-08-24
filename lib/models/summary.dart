// lib/models/summary.dart
// v1.21 | 작성일: 2025-08-24 | 작성자: GPT
import 'dart:convert';

class Summary {
  final String id;
  final String studentId;
  final String? teacherId;

  /// '기간별' | '키워드'
  final String? type;

  final DateTime? periodStart;
  final DateTime? periodEnd;

  final List<String> keywords;
  final List<String> selectedLessonIds;

  final Map<String, dynamic>? studentInfo;

  final String? resultStudent;
  final String? resultParent;
  final String? resultBlog;
  final String? resultTeacher;

  /// 예: ["teacher","admin"]
  final List<String> visibleTo;

  final DateTime? createdAt;

  Summary({
    required this.id,
    required this.studentId,
    this.teacherId,
    this.type,
    this.periodStart,
    this.periodEnd,
    this.keywords = const [],
    this.selectedLessonIds = const [],
    this.studentInfo,
    this.resultStudent,
    this.resultParent,
    this.resultBlog,
    this.resultTeacher,
    this.visibleTo = const ["teacher", "admin"],
    this.createdAt,
  });

  factory Summary.fromMap(Map<String, dynamic> map) {
    List<String> _asStringList(dynamic v) {
      if (v == null) return <String>[];
      if (v is List) {
        return v
            .map((e) => e?.toString() ?? "")
            .where((e) => e.isNotEmpty)
            .toList();
      }
      // jsonb가 문자열로 올 가능성 방어
      try {
        final parsed = jsonDecode(v.toString());
        if (parsed is List) {
          return parsed
              .map((e) => e?.toString() ?? "")
              .where((e) => e.isNotEmpty)
              .toList();
        }
      } catch (_) {}
      return <String>[];
    }

    DateTime? _asDate(dynamic v) {
      if (v == null) return null;
      // Supabase(Postgres date/timestamptz) 문자열 대응
      return DateTime.tryParse(v.toString());
    }

    return Summary(
      id: map['id']?.toString() ?? '',
      studentId: map['student_id']?.toString() ?? '',
      teacherId: map['teacher_id']?.toString(),
      type: map['type']?.toString(),
      periodStart: _asDate(map['period_start']),
      periodEnd: _asDate(map['period_end']),
      keywords: _asStringList(map['keywords']),
      selectedLessonIds: _asStringList(map['selected_lesson_ids']),
      studentInfo: (map['student_info'] as Map?)?.cast<String, dynamic>(),
      resultStudent: map['result_student']?.toString(),
      resultParent: map['result_parent']?.toString(),
      resultBlog: map['result_blog']?.toString(),
      resultTeacher: map['result_teacher']?.toString(),
      visibleTo: _asStringList(map['visible_to']),
      createdAt: _asDate(map['created_at']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'student_id': studentId,
      'teacher_id': teacherId,
      'type': type,
      'period_start': periodStart?.toIso8601String(),
      'period_end': periodEnd?.toIso8601String(),
      'keywords': keywords,
      'selected_lesson_ids': selectedLessonIds,
      'student_info': studentInfo,
      'result_student': resultStudent,
      'result_parent': resultParent,
      'result_blog': resultBlog,
      'result_teacher': resultTeacher,
      'visible_to': visibleTo,
      'created_at': createdAt?.toIso8601String(),
    };
  }
}
