import 'package:flutter/material.dart';

// 로그인 화면
import '../screens/auth/login_screen.dart';
import '../screens/auth/teacher_login.dart';
import '../screens/auth/admin_login.dart';

// 홈 화면
import '../screens/home/student_home_screen.dart';
import '../screens/home/teacher_home_screen.dart';
import '../screens/home/admin_home_screen.dart';

// 수업 화면
import '../screens/lesson/today_lesson_screen.dart';
import '../screens/lesson/lesson_history_screen.dart';
import '../screens/lesson/lesson_summary_screen.dart';

final Map<String, WidgetBuilder> appRoutes = {
  // 기본 시작 화면
  '/': (context) => const PlaceholderScreen(title: '홈'),

  // 로그인
  '/student_login': (context) => const StudentLoginScreen(),
  '/teacher_login': (context) => const TeacherLoginScreen(),
  '/admin_login': (context) => const AdminLoginScreen(),

  // 홈
  '/student_home': (context) => const StudentHomeScreen(),
  '/teacher_home': (context) => const TeacherHomeScreen(),
  '/admin_home': (context) => const AdminHomeScreen(),

  // 수업
  '/today_lesson': (context) => const TodayLessonScreen(),
  '/lesson_history': (context) => const LessonHistoryScreen(),
  '/lesson_summary': (context) => const LessonSummaryScreen(),
};

class PlaceholderScreen extends StatelessWidget {
  final String title;
  const PlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const Center(child: Text('여기는 홈입니다 🎸')),
    );
  }
}
