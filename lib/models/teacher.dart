class Teacher {
  final String id;
  final String name;
  final String email;
  final String passwordHash;
  final String? sheetId;
  final String createdAt;
  final String lastLogin;

  Teacher({
    required this.id,
    required this.name,
    required this.email,
    required this.passwordHash,
    required this.createdAt,
    required this.lastLogin,
    this.sheetId,
  });

  factory Teacher.fromMap(Map<String, dynamic> map, String docId) {
    return Teacher(
      id: docId,
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      passwordHash: map['passwordHash'] ?? '',
      createdAt: map['createdAt'] ?? '',
      lastLogin: map['lastLogin'] ?? '',
      sheetId: map['sheetId'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'passwordHash': passwordHash,
      'createdAt': createdAt,
      'lastLogin': lastLogin,
      'sheetId': sheetId,
    };
  }
}
