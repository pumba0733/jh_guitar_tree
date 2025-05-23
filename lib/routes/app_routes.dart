import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/teacher.dart';
import 'package:jh_guitar_tree/screens/auth/login_screen.dart';
import 'package:jh_guitar_tree/screens/home/staff_portal_screen.dart';

final Map<String, WidgetBuilder> appRoutes = {
  '/login': (context) => const LoginScreen(),
  '/staff_portal': (context) {
    final args = ModalRoute.of(context)!.settings.arguments as Teacher;
    return StaffPortalScreen(teacher: args);
  },
  // 이후 커리큘럼, 요약 등 화면 추가 가능
};
