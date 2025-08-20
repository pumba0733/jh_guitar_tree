import 'package:flutter/material.dart';
import 'routes/app_routes.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/student_home_screen.dart';
import 'screens/home/teacher_home_screen.dart';
import 'screens/home/admin_home_screen.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JH GuitarTree',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      initialRoute: AppRoutes.login,
      routes: {
        AppRoutes.login: (_) => const LoginScreen(),
        AppRoutes.studentHome: (_) => const StudentHomeScreen(),
        AppRoutes.teacherHome: (_) => const TeacherHomeScreen(),
        AppRoutes.adminHome: (_) => const AdminHomeScreen(),
      },
    );
  }
}
