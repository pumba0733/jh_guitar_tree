import 'package:cloud_firestore/cloud_firestore.dart';

class Student {
  final String id;
  final String name;
  final String gender;
  final bool isAdult;
  final String schoolName;
  final int grade;
  final DateTime startDate;
  final String teacherId;
  final String phoneNumber;
  final String memo;

  Student({
    required this.id,
    required this.name,
    required this.gender,
    required this.isAdult,
    required this.schoolName,
    required this.grade,
    required this.startDate,
    required this.teacherId,
    required this.phoneNumber,
    required this.memo,
  });

  // ✅ JSON 변환
  Map<String, dynamic> toJson() => {
    'name': name,
    'gender': gender,
    'isAdult': isAdult,
    'schoolName': schoolName,
    'grade': grade,
    'startDate': Timestamp.fromDate(startDate),
    'teacherId': teacherId,
    'phoneNumber': phoneNumber,
    'memo': memo,
  };

  // ✅ fromJson (with Firestore Timestamp safe parsing)
  factory Student.fromJson(Map<String, dynamic> json, String id) {
    final rawDate = json['startDate'];
    final parsedDate =
        rawDate is Timestamp
            ? rawDate.toDate()
            : DateTime.tryParse(rawDate?.toString() ?? '') ?? DateTime.now();

    return Student(
      id: id,
      name: json['name'] ?? '',
      gender: json['gender'] ?? '',
      isAdult: json['isAdult'] ?? false,
      schoolName: json['schoolName'] ?? '',
      grade: json['grade'] ?? 0,
      startDate: parsedDate,
      teacherId: json['teacherId'] ?? '',
      phoneNumber: json['phoneNumber'] ?? '',
      memo: json['memo'] ?? '',
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
    DateTime? startDate,
    String? teacherId,
    String? phoneNumber,
    String? memo,
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
      phoneNumber: phoneNumber ?? this.phoneNumber,
      memo: memo ?? this.memo,
    );
  }
}
