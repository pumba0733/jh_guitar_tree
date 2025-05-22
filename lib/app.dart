// 📄 lib/app.dart

import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/routes/app_routes.dart';
import 'package:jh_guitar_tree/services/auth_service.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JH GuitarTree',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Pretendard', // (선택) 전역 폰트 설정
      ),
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
