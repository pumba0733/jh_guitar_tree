// lib/models/lesson.dart
// v1.06 | 레슨 모델 (자동 저장/실시간)
class Lesson {
  final String id;
  final String studentId;
  final String? teacherId;
  final DateTime date;
  final String? subject;
  final List<String> keywords;
  final String? memo;
  final String? nextPlan;
  final String? youtubeUrl;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Lesson({
    required this.id,
    required this.studentId,
    this.teacherId,
    required this.date,
    this.subject,
    this.keywords = const [],
    this.memo,
    this.nextPlan,
    this.youtubeUrl,
    this.createdAt,
    this.updatedAt,
  });

  factory Lesson.fromMap(Map<String, dynamic> m) {
    return Lesson(
      id: m['id'] as String,
      studentId: m['student_id'] as String,
      teacherId: m['teacher_id'] as String?,
      date: DateTime.parse(m['date'] as String),
      subject: m['subject'] as String?,
      keywords: (m['keywords'] as List?)?.map((e) => '$e').toList() ?? const [],
      memo: m['memo'] as String?,
      nextPlan: m['next_plan'] as String?,
      youtubeUrl: m['youtube_url'] as String?,
      createdAt: m['created_at'] != null
          ? DateTime.tryParse(m['created_at'])
          : null,
      updatedAt: m['updated_at'] != null
          ? DateTime.tryParse(m['updated_at'])
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'student_id': studentId,
      'teacher_id': teacherId,
      'date': date.toIso8601String().substring(0, 10), // 'YYYY-MM-DD'
      'subject': subject,
      'keywords': keywords,
      'memo': memo,
      'next_plan': nextPlan,
      'youtube_url': youtubeUrl,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  Lesson copyWith({
    String? id,
    String? studentId,
    String? teacherId,
    DateTime? date,
    String? subject,
    List<String>? keywords,
    String? memo,
    String? nextPlan,
    String? youtubeUrl,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Lesson(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      teacherId: teacherId ?? this.teacherId,
      date: date ?? this.date,
      subject: subject ?? this.subject,
      keywords: keywords ?? this.keywords,
      memo: memo ?? this.memo,
      nextPlan: nextPlan ?? this.nextPlan,
      youtubeUrl: youtubeUrl ?? this.youtubeUrl,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
