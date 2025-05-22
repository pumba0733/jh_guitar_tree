import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/routes/app_routes.dart';
import 'package:jh_guitar_tree/services/auth_service.dart';

void main() {
  runApp(const MyApp()); // ✅ 앱 실행 진입점 추가됨
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JH GuitarTree',
      theme: ThemeData(primarySwatch: Colors.blue),
      debugShowCheckedModeBanner: false,
      routes: appRoutes,
      home: FutureBuilder<Widget>(
        future: AuthService().getInitialScreen(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          } else if (snapshot.hasError) {
            return const Scaffold(body: Center(child: Text("초기화 중 오류 발생")));
          } else {
            return snapshot.data!;
          }
        },
      ),
    );
  }
}
