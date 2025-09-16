// lib/app.dart
// v1.46.2 | 앱 레벨 보정 + 멀티학생 워크스페이스(루트 감시, 자동 매칭)
// - 세션 보정(AuthService.ensureTeacherLink) 유지
// - WORKSPACE_ENABLED + WORKSPACE_DIR만으로 macOS에서 루트(재귀) 감시 시작
// - 학생 UUID를 사전에 줄 필요 없음 (폴더/파일 규칙으로 자동 매칭)

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'routes/app_routes.dart';
import 'services/retry_queue_service.dart';
import 'services/auth_service.dart';
import 'constants/app_env.dart';
import 'services/workspace_service.dart';

// ---- Env 플래그 (Dart-define) ----
// 예시:
// --dart-define=WORKSPACE_ENABLED=true
// --dart-define=WORKSPACE_DIR=/Users/you/GuitarTreeWorkspace
const bool _workspaceEnabled = bool.fromEnvironment(
  'WORKSPACE_ENABLED',
  defaultValue: false,
);
const String _workspaceDir = String.fromEnvironment(
  'WORKSPACE_DIR',
  defaultValue: '',
);

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

    // ✅ 앱 시작 시 이미 세션이 있으면 1회 보정 + 워크스페이스 시작(옵션)
    final auth = Supabase.instance.client.auth;
    if (auth.currentUser != null) {
      unawaited(AuthService().ensureTeacherLink());
      _maybeStartWorkspace();
    }

    // ✅ 로그인/토큰갱신/유저업데이트/로그아웃 대응
    _authSub = auth.onAuthStateChange.listen((state) {
      final event = state.event;
      if (event == AuthChangeEvent.signedIn ||
          event == AuthChangeEvent.tokenRefreshed ||
          event == AuthChangeEvent.userUpdated) {
        unawaited(AuthService().ensureTeacherLink());
        _maybeStartWorkspace();
      } else if (event == AuthChangeEvent.signedOut) {
        _stopWorkspace();
      }
    });
  }

  void _maybeStartWorkspace() {
    // macOS + 플래그/경로 충족 시에만 시작, 이미 실행중이면 무시
    if (!Platform.isMacOS) return;
    if (!_workspaceEnabled) return;
    if (_workspaceDir.isEmpty) return;
    if (WorkspaceService.instance.isRunning) return;

    unawaited(WorkspaceService.instance.startRoot(folderPath: _workspaceDir));
  }

  void _stopWorkspace() {
    if (WorkspaceService.instance.isRunning) {
      unawaited(WorkspaceService.instance.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    _stopWorkspace(); // 안전 종료
    RetryQueueService().stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 포그라운드 복귀 시 즉시 한 번 flush
      RetryQueueService().flushAll();

      // 세션 살아있으면 워크스페이스 보정
      final auth = Supabase.instance.client.auth;
      if (auth.currentUser != null) {
        _maybeStartWorkspace();
      }
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
