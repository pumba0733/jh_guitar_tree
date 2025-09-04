// lib/app.dart
// v1.33.1 | 앱 레벨 보정: Supabase 세션 존재/변경 시 교사 링크 자동 동기화 + 기존 라우트 안전패치 유지
import 'dart:async' show StreamSubscription, unawaited;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'routes/app_routes.dart';
import 'services/retry_queue_service.dart';
import 'services/auth_service.dart';
import 'constants/app_env.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 앱 구동 후 주기적 flush 시작
    RetryQueueService().start(
      interval: Duration(seconds: AppEnv.retryIntervalSeconds),
    );

    // ✅ 앱 시작 시 이미 세션이 있으면 1회 보정
    final auth = Supabase.instance.client.auth;
    if (auth.currentUser != null) {
      unawaited(AuthService().ensureTeacherLink());
    }

    // ✅ 로그인/토큰갱신/유저업데이트 시에도 자동 보정
    _authSub = auth.onAuthStateChange.listen((state) {
      final event = state.event;
      if (event == AuthChangeEvent.signedIn ||
          event == AuthChangeEvent.tokenRefreshed ||
          event == AuthChangeEvent.userUpdated) {
        unawaited(AuthService().ensureTeacherLink());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    RetryQueueService().stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 포그라운드 복귀 시 즉시 한 번 flush
      RetryQueueService().flushAll();
      // (선택) 세션이 살아있다면 보정 한 번 더 해도 무해:
      // if (Supabase.instance.client.auth.currentUser != null) {
      //   unawaited(AuthService().ensureTeacherLink());
      // }
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
      // routes에 없는 라우트가 들어오는 경우에만 호출됨
      onGenerateRoute: AppRoutes.onGenerateRoute,
      onUnknownRoute: (_) => MaterialPageRoute(
        builder: (_) =>
            const Scaffold(body: Center(child: Text('알 수 없는 경로입니다.'))),
      ),
    );
  }
}
