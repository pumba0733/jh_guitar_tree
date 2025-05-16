import 'package:hive/hive.dart';

part 'lesson.g.dart';

@HiveType(typeId: 1)
class Lesson extends HiveObject {
  @HiveField(0)
  String studentId;

  @HiveField(1)
  String date;

  @HiveField(2)
  String subject;

  @HiveField(3)
  List<String> keywords;

  @HiveField(4)
  String memo;

  @HiveField(5)
  String nextPlan;

  @HiveField(6)
  List<String> audioPaths;

  @HiveField(7)
  String youtubeUrl;

  Lesson({
    required this.studentId,
    required this.date,
    required this.subject,
    required this.keywords,
    required this.memo,
    required this.nextPlan,
    required this.audioPaths,
    required this.youtubeUrl,
  });

  Map<String, dynamic> toMap() {
    return {
      'studentId': studentId,
      'date': date,
      'subject': subject,
      'keywords': keywords,
      'memo': memo,
      'nextPlan': nextPlan,
      'audioPaths': audioPaths,
      'youtubeUrl': youtubeUrl,
    };
  }
}
