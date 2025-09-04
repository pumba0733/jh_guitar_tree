// lib/models/student.dart
// v1.35.2 | Student 모델 확장 (설계서 정합: 성별/연령/학교/악기/시작일)
// - 핵심: id, name, phone_last4?, teacher_id?, created_at, updated_at
// - 운영: is_active, memo?
// - 설계서 추가: gender?, is_adult(bool), school_name?, grade?, start_date?, instrument?
// - DB 트리거 가정: updated_at 자동 갱신
// - snake_case 매핑 + 빈문자 → NULL 정규화 + Insert/Update 분리

import 'package:meta/meta.dart';

@immutable
class Student {
  // 기본/핵심
  final String id; // uuid (server)
  final String name; // not null
  final String? phoneLast4; // nullable
  final String? teacherId; // nullable
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // 운영
  final bool isActive; // default true
  final String? memo; // nullable

  // 설계서 추가 필드
  final String? gender; // '남' | '여' (text 저장)
  final bool isAdult; // true=성인, false=학생
  final String? schoolName; // 학교명(ㅇㅇ초/중/고) - 자유 텍스트
  final int? grade; // 학년(선택)
  final DateTime? startDate; // 시작일(등록날짜)
  final String? instrument; // '통기타' | '일렉기타' | '클래식기타' (text 저장)

  const Student({
    required this.id,
    required this.name,
    this.phoneLast4,
    this.teacherId,
    this.createdAt,
    this.updatedAt,
    this.isActive = true,
    this.memo,
    this.gender,
    this.isAdult = true, // 기본값: 성인
    this.schoolName,
    this.grade,
    this.startDate,
    this.instrument,
  });

  // ---------- parsing helpers ----------
  static String _s(dynamic v) => v == null ? '' : '$v';
  static String? _sOrNull(dynamic v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  static int? _iOrNull(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse('$v');
  }

  static DateTime? _dtOrNull(dynamic v) {
    if (v == null) return null;
    return DateTime.tryParse('$v');
  }

  // ---------- factory ----------
  factory Student.fromMap(Map<String, dynamic> m) {
    return Student(
      id: _s(m['id']),
      name: _s(m['name']),
      phoneLast4: _sOrNull(m['phone_last4']),
      teacherId: _sOrNull(m['teacher_id']),
      createdAt: _dtOrNull(m['created_at']),
      updatedAt: _dtOrNull(m['updated_at']),
      isActive: (m['is_active'] is bool)
          ? (m['is_active'] as bool)
          : (_s(m['is_active']).toLowerCase() == 'true'),
      memo: _sOrNull(m['memo']),
      gender: _sOrNull(m['gender']), // '남' | '여'
      isAdult: (m['is_adult'] is bool)
          ? (m['is_adult'] as bool)
          : (_s(m['is_adult']).toLowerCase() == 'true'),
      schoolName: _sOrNull(m['school_name']),
      grade: _iOrNull(m['grade']),
      startDate: _dtOrNull(m['start_date']),
      instrument: _sOrNull(m['instrument']),
    );
  }

  // ---------- normalizers ----------
  String? get normalizedTeacherId {
    final v = teacherId?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  static String? _normNullable(String? v) {
    if (v == null) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  static String? _normPhoneLast4(String? v) {
    if (v == null) return null;
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  // ---------- maps ----------
  /// INSERT: DB 기본값/트리거 활용 (id/created_at/updated_at 제외)
  Map<String, dynamic> toInsertMap() => {
    'name': name.trim(),
    'phone_last4': _normPhoneLast4(phoneLast4),
    'teacher_id': normalizedTeacherId,
    'is_active': isActive,
    'memo': _normNullable(memo),
    'gender': _normNullable(gender),
    'is_adult': isAdult,
    'school_name': _normNullable(schoolName),
    'grade': grade,
    'start_date': startDate?.toIso8601String(),
    'instrument': _normNullable(instrument),
  };

  /// UPDATE: 부분 업데이트 안전(빈문자→NULL), updated_at은 트리거에 위임
  Map<String, dynamic> toUpdateMap() => {
    'name': name.trim(),
    'phone_last4': _normPhoneLast4(phoneLast4),
    'teacher_id': normalizedTeacherId,
    'is_active': isActive,
    'memo': _normNullable(memo),
    'gender': _normNullable(gender),
    'is_adult': isAdult,
    'school_name': _normNullable(schoolName),
    'grade': grade,
    'start_date': startDate?.toIso8601String(),
    'instrument': _normNullable(instrument),
  };

  /// 직렬화(캐시/로컬 저장 등)
  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'phone_last4': phoneLast4,
    'teacher_id': teacherId,
    'created_at': createdAt?.toIso8601String(),
    'updated_at': updatedAt?.toIso8601String(),
    'is_active': isActive,
    'memo': memo,
    'gender': gender,
    'is_adult': isAdult,
    'school_name': schoolName,
    'grade': grade,
    'start_date': startDate?.toIso8601String(),
    'instrument': instrument,
  };

  // ---------- utils ----------
  static bool isValidPhoneLast4(String? v) {
    if (v == null) return true;
    final s = v.trim();
    if (s.isEmpty) return true;
    return RegExp(r'^[0-9]{4}$').hasMatch(s);
  }

  Student copyWith({
    String? id,
    String? name,
    String? phoneLast4,
    String? teacherId,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isActive,
    String? memo,
    String? gender,
    bool? isAdult,
    String? schoolName,
    int? grade,
    DateTime? startDate,
    String? instrument,
  }) {
    return Student(
      id: id ?? this.id,
      name: name ?? this.name,
      phoneLast4: (phoneLast4 == '') ? null : (phoneLast4 ?? this.phoneLast4),
      teacherId: (teacherId == '') ? null : (teacherId ?? this.teacherId),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isActive: isActive ?? this.isActive,
      memo: (memo == '') ? null : (memo ?? this.memo),
      gender: (gender == '') ? null : (gender ?? this.gender),
      isAdult: isAdult ?? this.isAdult,
      schoolName: (schoolName == '') ? null : (schoolName ?? this.schoolName),
      grade: grade ?? this.grade,
      startDate: startDate ?? this.startDate,
      instrument: (instrument == '') ? null : (instrument ?? this.instrument),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Student &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          phoneLast4 == other.phoneLast4 &&
          teacherId == other.teacherId &&
          isActive == other.isActive &&
          memo == other.memo &&
          gender == other.gender &&
          isAdult == other.isAdult &&
          schoolName == other.schoolName &&
          grade == other.grade &&
          startDate == other.startDate &&
          instrument == other.instrument &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode =>
      id.hashCode ^
      name.hashCode ^
      (phoneLast4 ?? '').hashCode ^
      (teacherId ?? '').hashCode ^
      isActive.hashCode ^
      (memo ?? '').hashCode ^
      (gender ?? '').hashCode ^
      isAdult.hashCode ^
      (schoolName ?? '').hashCode ^
      (grade ?? -1).hashCode ^
      (startDate?.millisecondsSinceEpoch ?? 0) ^
      (instrument ?? '').hashCode ^
      (createdAt?.millisecondsSinceEpoch ?? 0) ^
      (updatedAt?.millisecondsSinceEpoch ?? 0);
}
