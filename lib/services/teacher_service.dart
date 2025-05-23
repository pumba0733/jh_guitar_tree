// 📄 lib/services/teacher_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:jh_guitar_tree/models/teacher.dart';

class TeacherService {
  static final _collection = FirebaseFirestore.instance.collection('teachers');

  static Future<List<Teacher>> getAllTeachers() async {
    final snapshot = await _collection.get();
    return snapshot.docs
        .map((doc) => Teacher.fromJson(doc.id, doc.data()))
        .toList();
  }

  static Future<List<String>> getTeacherIds() async {
    final snapshot = await _collection.get();
    return snapshot.docs.map((doc) => doc.id).toList();
  }

  static Future<Teacher?> login(String identifier, String password) async {
    // 이름 또는 이메일 기준 로그인 처리
    final snapshot =
        await _collection
            .where(
              identifier.contains('@') ? 'email' : 'name',
              isEqualTo: identifier,
            )
            .limit(1)
            .get();

    if (snapshot.docs.isEmpty) return null;

    final doc = snapshot.docs.first;
    final data = doc.data();
    if (data['passwordHash'] != password) return null;

    return Teacher.fromJson(doc.id, data);
  }
}
