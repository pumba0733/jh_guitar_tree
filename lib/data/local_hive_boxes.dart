import 'package:hive/hive.dart';
import '../models/lesson.dart';

class LocalHiveBoxes {
  static const lessonBox = 'lesson_box';

  static Future<void> initHive() async {
    Hive.registerAdapter(LessonAdapter());
    await Hive.openBox<Lesson>(lessonBox);
  }

  static Box<Lesson> getLessonBox() {
    return Hive.box<Lesson>(lessonBox);
  }
}
