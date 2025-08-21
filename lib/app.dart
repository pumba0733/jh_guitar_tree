// lib/app.dart
import 'package:flutter/material.dart';
import 'routes/app_routes.dart';

// 화면 import (onGenerateRoute가 없어도 routes 맵으로 동작)
import 'screens/auth/login_screen.dart';
import 'screens/home/student_home_screen.dart';
import 'screens/home/teacher_home_screen.dart';
import 'screens/home/admin_home_screen.dart';
import 'screens/lesson/today_lesson_screen.dart';
import 'screens/lesson/lesson_history_screen.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'JH GuitarTree',
      // ✅ 초기 라우트: 필요에 따라 변경 (예: AppRoutes.login)
      initialRoute: AppRoutes.login,
      // ✅ 정적 라우트 테이블 등록
      routes: AppRoutes.routes,
      // (선택) 예비 onGenerateRoute: 실수로 맵에 빠져도 안전하게
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case AppRoutes.login:
            return MaterialPageRoute(builder: (_) => const LoginScreen());
          case AppRoutes.studentHome:
            return MaterialPageRoute(builder: (_) => const StudentHomeScreen());
          case AppRoutes.teacherHome:
            return MaterialPageRoute(builder: (_) => const TeacherHomeScreen());
          case AppRoutes.adminHome:
            return MaterialPageRoute(builder: (_) => const AdminHomeScreen());
          case AppRoutes.todayLesson:
            return MaterialPageRoute(builder: (_) => const TodayLessonScreen());
          case AppRoutes.lessonHistory:
            return MaterialPageRoute(
              builder: (_) => const LessonHistoryScreen(),
            );
        }
        // ✅ 알 수 없는 경로 방지
        return MaterialPageRoute(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('알 수 없는 경로입니다.'))),
        );
      },
    );
  }
}
