class Student {
  final String id;
  final String name;
  final String gender;
  final bool isAdult;
  final String schoolName;
  final int grade;
  final String startDate;
  final String? instrument;
  final String? teacherId;

  Student({
    required this.id,
    required this.name,
    required this.gender,
    required this.isAdult,
    required this.schoolName,
    required this.grade,
    required this.startDate,
    this.instrument,
    this.teacherId,
  });

  factory Student.fromMap(Map<String, dynamic> map, String docId) {
    return Student(
      id: docId,
      name: map['name'] ?? '',
      gender: map['gender'] ?? '',
      isAdult: map['isAdult'] ?? false,
      schoolName: map['schoolName'] ?? '',
      grade: map['grade'] ?? 0,
      startDate: map['startDate'] ?? '',
      instrument: map['instrument'],
      teacherId: map['teacherId'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'gender': gender,
      'isAdult': isAdult,
      'schoolName': schoolName,
      'grade': grade,
      'startDate': startDate,
      'instrument': instrument,
      'teacherId': teacherId,
    };
  }
}
