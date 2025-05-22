class Student {
  final String id;
  final String name;
  final String gender;
  final bool isAdult;
  final String schoolName;
  final int grade;
  final String startDate;
  final String teacherId;
  final String memo;
  final String phoneSuffix;

  Student({
    required this.id,
    required this.name,
    required this.gender,
    required this.isAdult,
    required this.schoolName,
    required this.grade,
    required this.startDate,
    required this.teacherId,
    required this.memo,
    required this.phoneSuffix,
  });

  // ✅ JSON 변환
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'gender': gender,
    'isAdult': isAdult,
    'schoolName': schoolName,
    'grade': grade,
    'startDate': startDate,
    'teacherId': teacherId,
    'memo': memo,
    'phoneSuffix': phoneSuffix,
  };

  // ✅ fromJson
  factory Student.fromJson(Map<String, dynamic> json, String id) {
    return Student(
      id: id,
      name: json['name'] ?? '',
      gender: json['gender'] ?? '',
      isAdult: json['isAdult'] ?? false,
      schoolName: json['schoolName'] ?? '',
      grade: json['grade'] ?? 0,
      startDate: json['startDate'] ?? '',
      teacherId: json['teacherId'] ?? '',
      memo: json['memo'] ?? '',
      phoneSuffix: json['phoneSuffix'] ?? '',
    );
  }

  // ✅ copyWith
  Student copyWith({
    String? id,
    String? name,
    String? gender,
    bool? isAdult,
    String? schoolName,
    int? grade,
    String? startDate,
    String? teacherId,
    String? memo,
    String? phoneSuffix,
  }) {
    return Student(
      id: id ?? this.id,
      name: name ?? this.name,
      gender: gender ?? this.gender,
      isAdult: isAdult ?? this.isAdult,
      schoolName: schoolName ?? this.schoolName,
      grade: grade ?? this.grade,
      startDate: startDate ?? this.startDate,
      teacherId: teacherId ?? this.teacherId,
      memo: memo ?? this.memo,
      phoneSuffix: phoneSuffix ?? this.phoneSuffix,
    );
  }
}
