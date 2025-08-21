// lib/models/student.dart
class Student {
  final String id;
  final String name;
  final String? phoneLast4;
  final String? teacherId;
  final DateTime? createdAt;

  Student({
    required this.id,
    required this.name,
    this.phoneLast4,
    this.teacherId,
    this.createdAt,
  });

  factory Student.fromMap(Map<String, dynamic> m) => Student(
    id: m['id'] as String,
    name: m['name'] as String,
    phoneLast4: m['phone_last4'] as String?,
    teacherId: m['teacher_id'] as String?,
    createdAt: m['created_at'] != null ? DateTime.parse(m['created_at']) : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'phone_last4': phoneLast4,
    'teacher_id': teacherId,
    'created_at': createdAt?.toIso8601String(),
  };
}
