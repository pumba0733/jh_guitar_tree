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
}
