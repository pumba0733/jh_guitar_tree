import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/services/auth_service.dart';

class StudentService {
  final _studentsRef = FirebaseFirestore.instance.collection('students');

  // ✅ 학생 추가
  Future<void> addStudent(Student student) async {
    final docRef = _studentsRef.doc();
    final newStudent = student.copyWith(id: docRef.id);
    await docRef.set(newStudent.toJson());
  }

  // ✅ 학생 수정
  Future<void> updateStudent(Student student) async {
    if (student.id.isEmpty) return;
    await _studentsRef.doc(student.id).update(student.toJson());
  }

  // ✅ 메모 수정
  Future<void> updateMemo(String studentId, String memo) async {
    await _studentsRef.doc(studentId).update({'memo': memo});
  }

  // ✅ 학생 삭제
  Future<void> deleteStudent(String studentId) async {
    await _studentsRef.doc(studentId).delete();
  }

  // ✅ 전체 학생 조회 (관리자 or 강사/본인 기준 분기)
  Stream<List<Student>> getAccessibleStudents() {
    final role = AuthService().currentUserRole;
    final uid = AuthService().currentUserId;

    if (role == 'admin') {
      // 관리자 → 전체 학생 조회
      return _studentsRef.snapshots().map(
        (snapshot) =>
            snapshot.docs
                .map((doc) => Student.fromJson(doc.data(), doc.id))
                .toList(),
      );
    } else {
      // 강사 → 본인 담당 학생만
      return _studentsRef
          .where('teacherId', isEqualTo: uid)
          .snapshots()
          .map(
            (snapshot) =>
                snapshot.docs
                    .map((doc) => Student.fromJson(doc.data(), doc.id))
                    .toList(),
          );
    }
  }
}
