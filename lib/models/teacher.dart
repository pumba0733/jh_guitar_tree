// v1.36.1 | Teacher 모델 확장: isAdmin, authUserId, lastLogin 포함
class Teacher {
  final String id;
  final String name;
  final String email;
  final bool isAdmin;
  final String? authUserId;
  final DateTime? lastLogin;

  const Teacher({
    required this.id,
    required this.name,
    required this.email,
    required this.isAdmin,
    this.authUserId,
    this.lastLogin,
  });

  factory Teacher.fromMap(Map<String, dynamic> map) {
    return Teacher(
      id: map['id'] as String,
      name: (map['name'] as String?)?.trim() ?? '',
      email: (map['email'] as String?)?.trim() ?? '',
      isAdmin: (map['is_admin'] as bool?) ?? false,
      authUserId: map['auth_user_id'] as String?,
      lastLogin: map['last_login'] != null
          ? DateTime.tryParse(map['last_login'] as String)
          : null,
    );
  }

  Teacher copyWith({String? name, String? email, bool? isAdmin}) {
    return Teacher(
      id: id,
      name: name ?? this.name,
      email: email ?? this.email,
      isAdmin: isAdmin ?? this.isAdmin,
      authUserId: authUserId,
      lastLogin: lastLogin,
    );
  }
}
