// lib/app.dart
// v1.21.2 | 재시도 큐 주기 동작 + 라우트 등록
import 'package:flutter/material.dart';
import 'routes/app_routes.dart';
import 'services/retry_queue_service.dart';
import 'constants/app_env.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 앱 구동 후 주기적 flush 시작
    RetryQueueService().start(
      interval: Duration(seconds: AppEnv.retryIntervalSeconds),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RetryQueueService().stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 포그라운드 복귀 시 즉시 한 번 flush
      RetryQueueService().flushAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.indigo,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'JH GuitarTree',
      theme: theme,
      initialRoute: AppRoutes.login,
      routes: AppRoutes.routes,
      onUnknownRoute: (_) => MaterialPageRoute(
        builder: (_) =>
            const Scaffold(body: Center(child: Text('알 수 없는 경로입니다.'))),
      ),
    );
  }
}
