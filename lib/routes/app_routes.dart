// lib/routes/app_routes.dart
// v1.39.5 | 커리큘럼 Studio/Browser/StudentCurriculum 라우트 추가 + BadArgsScreen 키 파라미터 제거
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

// 커리큘럼
import '../screens/curriculum/curriculum_overview_screen.dart';
import '../screens/curriculum/curriculum_studio_screen.dart';
import '../screens/curriculum/curriculum_browser_screen.dart';
import '../screens/curriculum/student_curriculum_screen.dart';

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

  // 커리큘럼
  static const String curriculumOverview =
      '/curriculum_overview'; // 열람/검색(간단 배정)
  static const String curriculumStudio = '/curriculum_studio'; // 관리자 편집/CRUD
  static const String curriculumBrowser = '/curriculum_browser'; // 강사용 열람/배정
  static const String studentCurriculum =
      '/student_curriculum'; // 학생별 진행(인자 필요)

  // ===== 정적 라우트 맵 =====
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

    // 커리큘럼
    curriculumOverview: (_) => const CurriculumOverviewScreen(),
    curriculumStudio: (_) => const CurriculumStudioScreen(),
    curriculumBrowser: (_) => const CurriculumBrowserScreen(),
    // studentCurriculum 은 인자 필요 → onGenerateRoute 처리
  };

  // ===== onGenerateRoute (인자 필요한 라우트 처리) =====
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case studentCurriculum:
        final args = settings.arguments;
        String? studentId;
        if (args is Map) {
          final v = args['studentId'];
          if (v is String) studentId = v;
        }
        if (studentId == null || studentId.trim().isEmpty) {
          return MaterialPageRoute(
            builder: (_) => const _BadArgsScreen(
              title: '학생 커리큘럼',
              message: 'studentId 가 필요합니다.',
            ),
            settings: settings,
          );
        }
        return MaterialPageRoute(
          builder: (_) => StudentCurriculumScreen(studentId: studentId!),
          settings: settings,
        );
    }
    return null; // 나머지는 routes 맵에서 처리
  }

  // ===== 편의 push 헬퍼 =====
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

  static Future<T?> pushCurriculumOverview<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, curriculumOverview);
  }

  static Future<T?> pushCurriculumStudio<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, curriculumStudio);
  }

  static Future<T?> pushCurriculumBrowser<T>(BuildContext context) {
    return Navigator.pushNamed<T>(context, curriculumBrowser);
  }

  static Future<T?> pushStudentCurriculum<T>(
    BuildContext context, {
    required String studentId,
  }) {
    return Navigator.pushNamed<T>(
      context,
      studentCurriculum,
      arguments: {'studentId': studentId},
    );
  }

  // ===== 타입 안전 Args =====
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

  static Map<String, dynamic> lessonHistoryArgs({required String studentId}) {
    return {'studentId': studentId};
  }

  static Map<String, dynamic> lessonSummaryArgs({
    required String studentId,
    String? teacherId,
  }) {
    return {
      'studentId': studentId,
      if (teacherId != null) 'teacherId': teacherId,
    };
  }
}

// 잘못된 arguments 안내용 간단 화면 (key 파라미터 제거로 린트 회피)
class _BadArgsScreen extends StatelessWidget {
  final String title;
  final String message;

  const _BadArgsScreen({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(child: Text(message)),
    );
  }
}
