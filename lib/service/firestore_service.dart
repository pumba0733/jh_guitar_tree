import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/lesson.dart';

class FirestoreService {
  static final _db = FirebaseFirestore.instance;

  static Future<void> saveLessonToFirestore(Lesson lesson) async {
    final docId = '${lesson.studentId}_${lesson.date}';
    await _db.collection('lessons').doc(docId).set(lesson.toMap());
  }
}
