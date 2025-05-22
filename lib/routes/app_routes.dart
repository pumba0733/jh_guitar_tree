import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/screens/auth/login_screen.dart';
import 'package:jh_guitar_tree/screens/home/student_home_screen.dart';
import 'package:jh_guitar_tree/screens/home/staff_portal_screen.dart';
// 필요한 화면 추가 가능

final Map<String, WidgetBuilder> appRoutes = {
  '/login': (context) => const LoginScreen(),
  '/student_home': (context) => const StudentHomeScreen(),
  '/staff_portal': (context) => const StaffPortalScreen(),
  // 이후 커리큘럼, 요약 등 화면 추가 가능
};
