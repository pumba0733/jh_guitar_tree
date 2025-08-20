import 'package:meta/meta.dart';

@immutable
class Student {
  final String id;
  final String name;
  final String phoneLast4;
  final String? teacherId;
  final DateTime? createdAt;

  const Student({
    required this.id,
    required this.name,
    required this.phoneLast4,
    this.teacherId,
    this.createdAt,
  });

  factory Student.fromMap(Map<String, dynamic> map) {
    return Student(
      id: map['id'] as String,
      name: map['name'] as String? ?? '',
      phoneLast4: map['phone_last4'] as String? ?? '',
      teacherId: map['teacher_id'] as String?,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'phone_last4': phoneLast4,
      'teacher_id': teacherId,
      'created_at': createdAt?.toIso8601String(),
    };
  }
}
