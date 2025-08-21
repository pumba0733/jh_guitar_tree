// lib/routes/app_routes.dart
import 'package:flutter/widgets.dart';

import '../screens/auth/login_screen.dart';
import '../screens/home/student_home_screen.dart';
import '../screens/home/teacher_home_screen.dart';
import '../screens/home/admin_home_screen.dart';
import '../screens/lesson/today_lesson_screen.dart';
import '../screens/lesson/lesson_history_screen.dart';

class AppRoutes {
  // 기본/인증
  static const String login = '/login';

  // 홈
  static const String studentHome = '/student_home';
  static const String teacherHome = '/teacher_home';
  static const String adminHome = '/admin_home';

  // v1.04 추가
  static const String todayLesson = '/today_lesson';
  static const String lessonHistory = '/lesson_history';

  // 정적 라우트 맵
  static final Map<String, WidgetBuilder> routes = {
    login: (_) => const LoginScreen(),
    studentHome: (_) => const StudentHomeScreen(),
    teacherHome: (_) => const TeacherHomeScreen(),
    adminHome: (_) => const AdminHomeScreen(),
    todayLesson: (_) => const TodayLessonScreen(),
    lessonHistory: (_) => const LessonHistoryScreen(),
  };
}
