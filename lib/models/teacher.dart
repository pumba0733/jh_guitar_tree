// 📄 lib/models/teacher.dart

class Teacher {
  final String id;
  final String name;
  final String email;
  final String sheetId;
  final String role;
  final String passwordHash;

  Teacher({
    required this.id,
    required this.name,
    required this.email,
    required this.sheetId,
    required this.role,
    required this.passwordHash,
  });

  factory Teacher.fromJson(String id, Map<String, dynamic> json) {
    return Teacher(
      id: id,
      name: json['name'] ?? '',
      email: json['email'] ?? '',
      sheetId: json['sheetId'] ?? '',
      role: json['role'] ?? 'teacher',
      passwordHash: json['passwordHash'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'email': email,
    'sheetId': sheetId,
    'role': role,
    'passwordHash': passwordHash,
  };
}
