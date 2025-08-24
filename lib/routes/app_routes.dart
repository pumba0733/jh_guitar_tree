// lib/routes/app_routes.dart
import 'package:flutter/material.dart';

// 로그인/홈
import '../screens/auth/login_screen.dart';
import '../screens/home/student_home_screen.dart';
import '../screens/home/teacher_home_screen.dart';
import '../screens/home/admin_home_screen.dart';

// 레슨
import '../screens/lesson/today_lesson_screen.dart';
import '../screens/lesson/lesson_history_screen.dart';
import '../screens/lesson/summary_result_screen.dart';

// 요약
import '../screens/summary/lesson_summary_screen.dart';

// 관리
import '../screens/manage/manage_students_screen.dart';
import '../screens/manage/manage_teachers_screen.dart';
import '../screens/manage/manage_keywords_screen.dart';

// 설정
import '../screens/settings/logs_screen.dart';
import '../screens/settings/export_screen.dart';
import '../screens/settings/import_screen.dart';
import '../screens/settings/change_password_screen.dart';

class AppRoutes {
  // 기본/인증
  static const String login = '/login';

  // 홈
  static const String studentHome = '/student_home';
  static const String teacherHome = '/teacher_home';
  static const String adminHome = '/admin_home';

  // 레슨
  static const String todayLesson = '/today_lesson';
  static const String lessonHistory = '/lesson_history';
  static const String summaryResult = '/summary_result';

  // 요약
  static const String lessonSummary = '/lesson_summary';

  // 관리
  static const String manageStudents = '/manage_students';
  static const String manageTeachers = '/manage_teachers';
  static const String manageKeywords = '/manage_keywords';

  // 설정
  static const String logs = '/logs';
  static const String export = '/export';
  static const String import = '/import';
  static const String changePassword = '/change_password';

  static Map<String, WidgetBuilder> get routes => <String, WidgetBuilder>{
    login: (_) => const LoginScreen(),
    studentHome: (_) => const StudentHomeScreen(),
    teacherHome: (_) => const TeacherHomeScreen(),
    adminHome: (_) => const AdminHomeScreen(),

    todayLesson: (_) => const TodayLessonScreen(),
    lessonHistory: (_) => const LessonHistoryScreen(),
    summaryResult: (_) => const SummaryResultScreen(),

    lessonSummary: (_) => const LessonSummaryScreen(),

    manageStudents: (_) => const ManageStudentsScreen(),
    manageTeachers: (_) => const ManageTeachersScreen(),
    manageKeywords: (_) => const ManageKeywordsScreen(),

    logs: (_) => const LogsScreen(),
    export: (_) => const ExportScreen(),
    import: (_) => const ImportScreen(),
    changePassword: (_) => const ChangePasswordScreen(),
  };
}
