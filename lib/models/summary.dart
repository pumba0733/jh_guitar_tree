class Summary {
  final String id;
  final String studentId;
  final String teacherId;
  final String type;
  final String periodStart;
  final String periodEnd;
  final List<String> keywords;
  final List<String> selectedLessons;
  final Map<String, dynamic> studentInfo;
  final String resultStudent;
  final String resultParent;
  final String resultBlog;
  final String resultTeacher;
  final List<String> visibleTo;

  Summary({
    required this.id,
    required this.studentId,
    required this.teacherId,
    required this.type,
    required this.periodStart,
    required this.periodEnd,
    required this.keywords,
    required this.selectedLessons,
    required this.studentInfo,
    required this.resultStudent,
    required this.resultParent,
    required this.resultBlog,
    required this.resultTeacher,
    required this.visibleTo,
  });

  factory Summary.fromMap(Map<String, dynamic> map, String docId) {
    return Summary(
      id: docId,
      studentId: map['studentId'] ?? '',
      teacherId: map['teacherId'] ?? '',
      type: map['type'] ?? '',
      periodStart: map['periodStart'] ?? '',
      periodEnd: map['periodEnd'] ?? '',
      keywords: List<String>.from(map['keywords'] ?? []),
      selectedLessons: List<String>.from(map['selectedLessons'] ?? []),
      studentInfo: Map<String, dynamic>.from(map['studentInfo'] ?? {}),
      resultStudent: map['resultStudent'] ?? '',
      resultParent: map['resultParent'] ?? '',
      resultBlog: map['resultBlog'] ?? '',
      resultTeacher: map['resultTeacher'] ?? '',
      visibleTo: List<String>.from(map['visibleTo'] ?? []),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'studentId': studentId,
      'teacherId': teacherId,
      'type': type,
      'periodStart': periodStart,
      'periodEnd': periodEnd,
      'keywords': keywords,
      'selectedLessons': selectedLessons,
      'studentInfo': studentInfo,
      'resultStudent': resultStudent,
      'resultParent': resultParent,
      'resultBlog': resultBlog,
      'resultTeacher': resultTeacher,
      'visibleTo': visibleTo,
    };
  }
}
