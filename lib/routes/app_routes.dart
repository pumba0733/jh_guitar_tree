// lib/routes/app_routes.dart
// v1.31.0 | 라우트 상수 + 안전 Args + push 헬퍼 + onGenerateRoute 보강(선택적)
// 작성자: GPT

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
  // ===== 경로 상수 =====
  // 기본/인증
  static const String login = '/login';

  // 홈
  static const String studentHome = '/student_home';
  static const String teacherHome = '/teacher_home';
  static const String adminHome = '/admin_home';

  // 레슨
  static const String todayLesson = '/today_lesson';
  static const String lessonHistory = '/lesson_history';

  // 요약
  static const String lessonSummary = '/lesson_summary';
  static const String summaryResult = '/summary_result';

  // 관리
  static const String manageStudents = '/manage_students';
  static const String manageTeachers = '/manage_teachers';
  static const String manageKeywords = '/manage_keywords';

  // 설정
  static const String logs = '/logs';
  static const String export = '/export';
  static const String importData = '/import';
  static const String changePassword = '/change_password';

  // ===== 타입 안전 Args (선택 사용) =====
  // TodayLesson: studentId 필수, teacherId/lessonId 옵션
  static Map<String, dynamic> todayLessonArgs({
    required String studentId,
    String? teacherId,
    String? lessonId,
  }) {
    return {
      'studentId': studentId,
      if (teacherId != null) 'teacherId': teacherId,
      if (lessonId != null) 'lessonId': lessonId,
    };
  }

  // LessonHistory: studentId 필수
  static Map<String, dynamic> lessonHistoryArgs({required String studentId}) {
    return {'studentId': studentId};
  }

  // LessonSummary: studentId 필수, teacherId 옵션
  static Map<String, dynamic> lessonSummaryArgs({
    required String studentId,
    String? teacherId,
  }) {
    return {
      'studentId': studentId,
      if (teacherId != null) 'teacherId': teacherId,
    };
  }

  // ===== 정적 라우트 맵 (기본) =====
  static Map<String, WidgetBuilder> get routes => {
    // 기본/인증
    login: (_) => const LoginScreen(),

    // 홈
    studentHome: (_) => const StudentHomeScreen(),
    teacherHome: (_) => const TeacherHomeScreen(),
    adminHome: (_) => const AdminHomeScreen(),

    // 레슨
    todayLesson: (_) => const TodayLessonScreen(),
    lessonHistory: (_) => const LessonHistoryScreen(),

    // 요약
    lessonSummary: (_) => const LessonSummaryScreen(),
    summaryResult: (_) => const SummaryResultScreen(),

    // 관리
    manageStudents: (_) => const ManageStudentsScreen(),
    manageTeachers: (_) => const ManageTeachersScreen(),
    manageKeywords: (_) => const ManageKeywordsScreen(),

    // 설정
    logs: (_) => const LogsScreen(),
    export: (_) => const ExportScreen(),
    importData: (_) => const ImportScreen(),
    changePassword: (_) => const ChangePasswordScreen(),
  };

  // ===== 선택: 보강형 onGenerateRoute =====
  // - 알려진 라우트이나 arguments가 잘못 온 경우 친절한 에러 화면 표시
  // - routes 맵에 없는 경우에만 호출됨(Flutter 동작 규칙)
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    // 현재는 routes 맵이 모든 라우트를 커버하므로 특별 처리 불필요.
    // 추후 동적 라우팅/깊은링크가 필요하면 여기서 분기.
    return null;
  }

  // ===== 편의 push 헬퍼 (선택) =====
  static Future<T?> pushTodayLesson<T>(
    BuildContext context, {
    required String studentId,
    String? teacherId,
    String? lessonId,
  }) {
    return Navigator.pushNamed<T>(
      context,
      todayLesson,
      arguments: todayLessonArgs(
        studentId: studentId,
        teacherId: teacherId,
        lessonId: lessonId,
      ),
    );
  }

  static Future<T?> pushLessonHistory<T>(
    BuildContext context, {
    required String studentId,
  }) {
    return Navigator.pushNamed<T>(
      context,
      lessonHistory,
      arguments: lessonHistoryArgs(studentId: studentId),
    );
    // LessonHistoryScreen에서 ModalRoute로 Map 읽거나,
    // 추후 Args 클래스로 캐스팅하도록 리팩터링 가능.
  }

  static Future<T?> pushLessonSummary<T>(
    BuildContext context, {
    required String studentId,
    String? teacherId,
  }) {
    return Navigator.pushNamed<T>(
      context,
      lessonSummary,
      arguments: lessonSummaryArgs(studentId: studentId, teacherId: teacherId),
    );
  }
}
