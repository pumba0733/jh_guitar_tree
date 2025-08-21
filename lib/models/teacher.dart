// lib/models/teacher.dart
class Teacher {
  final String id;
  final String name;
  final String email;

  const Teacher({required this.id, required this.name, required this.email});

  factory Teacher.fromMap(Map<String, dynamic> map) {
    return Teacher(
      id: map['id'] as String,
      name: map['name'] as String,
      email: map['email'] as String,
    );
  }
}
