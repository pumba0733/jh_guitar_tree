// lib/app.dart
import 'package:flutter/material.dart';
import 'routes/app_routes.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.indigo,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      appBarTheme: const AppBarTheme(centerTitle: true),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'JH GuitarTree',
      theme: theme,
      initialRoute: AppRoutes.login,
      routes: AppRoutes.routes,
      onUnknownRoute: (_) => MaterialPageRoute(
        builder: (_) => const Scaffold(
          body: Center(child: Text('알 수 없는 경로입니다.')),
        ),
      ),
    );
  }
}
