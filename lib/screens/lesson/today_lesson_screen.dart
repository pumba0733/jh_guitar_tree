// 📄 lib/screens/lesson/today_lesson_screen.dart

import 'package:flutter/material.dart';

class TodayLessonScreen extends StatelessWidget {
  const TodayLessonScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('오늘 수업')),
      body: const Center(child: Text('여기는 TodayLesson 화면입니다')),
    );
  }
}
