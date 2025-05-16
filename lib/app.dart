import 'package:flutter/material.dart';
import 'routes/app_routes.dart';

class JHGuitarTreeApp extends StatelessWidget {
  const JHGuitarTreeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JH GuitarTree',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Pretendard',
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
      ),
      initialRoute: '/',
      routes: appRoutes,
    );
  }
}
