// lib/models/lesson.dart
// v1.46.0 | next_plan 완전 제거

class Lesson {
  final String id;
  final String studentId;
  final String? teacherId;
  final DateTime date;
  final String? subject;
  final List<String> keywords;
  final String? memo;
  final String? youtubeUrl;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Lesson({
    required this.id,
    required this.studentId,
    required this.date,
    this.teacherId,
    this.subject,
    this.keywords = const [],
    this.memo,
    this.youtubeUrl,
    this.createdAt,
    this.updatedAt,
  });

  Lesson copyWith({
    String? subject,
    List<String>? keywords,
    String? memo,
    String? youtubeUrl,
  }) => Lesson(
    id: id,
    studentId: studentId,
    date: date,
    teacherId: teacherId,
    subject: subject ?? this.subject,
    keywords: keywords ?? this.keywords,
    memo: memo ?? this.memo,
    youtubeUrl: youtubeUrl ?? this.youtubeUrl,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory Lesson.fromMap(Map<String, dynamic> m) {
    return Lesson(
      id: m['id'] as String,
      studentId: m['student_id'] as String,
      teacherId: m['teacher_id'] as String?,
      date: DateTime.parse('${m['date']}'),
      subject: m['subject'] as String?,
      keywords: (m['keywords'] as List?)?.map((e) => '$e').toList() ?? const [],
      memo: m['memo'] as String?,
      youtubeUrl: m['youtube_url'] as String?,
      createdAt: m['created_at'] != null
          ? DateTime.tryParse('${m['created_at']}')
          : null,
      updatedAt: m['updated_at'] != null
          ? DateTime.tryParse('${m['updated_at']}')
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'student_id': studentId,
    'teacher_id': teacherId,
    'date': date.toIso8601String(),
    'subject': subject,
    'keywords': keywords,
    'memo': memo,
    'youtube_url': youtubeUrl,
    'created_at': createdAt?.toIso8601String(),
    'updated_at': updatedAt?.toIso8601String(),
  };
}
