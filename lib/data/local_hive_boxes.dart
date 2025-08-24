// lib/data/local_hive_boxes.dart
// v1.21.2 Hive 박스 정의(캐시 + 재시도 큐)
import 'package:hive/hive.dart';

class LocalHiveBoxes {
  static Future<void> init() async {
    // 박스 오픈은 지연 오픈 방식을 권장합니다.
    // main()에서 Hive.initFlutter() 또는 플랫폼별 Hive.init(path) 1회 수행이 이상적입니다.
  }

  static Future<Box> openLessonCache() => Hive.openBox('lesson_cache_box');
  static Future<Box> openSummaryCache() => Hive.openBox('summary_cache_box');
  static Future<Box> openRetryQueue() => Hive.openBox('retry_queue_box');
}
