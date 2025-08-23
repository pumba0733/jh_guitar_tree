// lib/models/student.dart
// v1.05 | 2025-08-24 | 로그인/리스트 공용 모델
class Student {
  final String id;
  final String name;
  final String phoneLast4;
  final String? teacherId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Student({
    required this.id,
    required this.name,
    required this.phoneLast4,
    this.teacherId,
    this.createdAt,
    this.updatedAt,
  });

  factory Student.fromMap(Map<String, dynamic> m) {
    return Student(
      id: m['id'] as String,
      name: (m['name'] ?? '') as String,
      phoneLast4: (m['phone_last4'] ?? '') as String,
      teacherId: m['teacher_id'] as String?,
      createdAt: m['created_at'] != null
          ? DateTime.tryParse(m['created_at'])
          : null,
      updatedAt: m['updated_at'] != null
          ? DateTime.tryParse(m['updated_at'])
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'phone_last4': phoneLast4,
    'teacher_id': teacherId,
    'created_at': createdAt?.toIso8601String(),
    'updated_at': updatedAt?.toIso8601String(),
  };
}
