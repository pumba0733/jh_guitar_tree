// 📄 lib/models/teacher.dart

class Teacher {
  final String id;
  final String name;
  final String email;
  final String sheetId;

  Teacher({
    required this.id,
    required this.name,
    required this.email,
    required this.sheetId,
  });

  factory Teacher.fromJson(String id, Map<String, dynamic> json) {
    return Teacher(
      id: id,
      name: json['name'] ?? '',
      email: json['email'] ?? '',
      sheetId: json['sheetId'] ?? '',
    );
  }
}
