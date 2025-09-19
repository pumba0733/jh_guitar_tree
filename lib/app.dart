// lib/app.dart
// v1.58.1 | 앱 레벨 보정 + 세션 복원 + 멀티학생 워크스페이스
// - 부팅/세션변경 시 AuthService.restoreLinkedIdentities() 호출 추가
// - 기존 ensureTeacherLink()는 유지 (교사 이메일-레코드 링크 보강)
// - WORKSPACE_ENABLED/WORKSPACE_DIR 조건에 맞을 때만 macOS 루트 감시

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

    // 주기적 flush 시작
    RetryQueueService().start(
      interval: Duration(seconds: AppEnv.retryIntervalSeconds),
    );

    // ✅ 부팅 직후: 세션이 이미 있다면 1회 복원 + 링크 보강 + 워크스페이스 시작
    final auth = Supabase.instance.client.auth;
    if (auth.currentUser != null) {
      unawaited(AuthService().restoreLinkedIdentities()); // 교사 세션↔DB 재결합
      unawaited(AuthService().ensureTeacherLink()); // 이메일 링크 보강
      _maybeStartWorkspace();
    }

    // ✅ 로그인/토큰갱신/유저업데이트/로그아웃 대응
    _authSub = auth.onAuthStateChange.listen((state) {
      final event = state.event;
      if (event == AuthChangeEvent.signedIn ||
          event == AuthChangeEvent.tokenRefreshed ||
          event == AuthChangeEvent.userUpdated) {
        unawaited(AuthService().restoreLinkedIdentities());
        unawaited(AuthService().ensureTeacherLink());
        _maybeStartWorkspace();
      } else if (event == AuthChangeEvent.signedOut) {
        _stopWorkspace();
      }
    });
  }

  void _maybeStartWorkspace() {
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
      // 포그라운드 복귀 시 즉시 flush
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
      onGenerateRoute: AppRoutes.onGenerateRoute,
      onUnknownRoute: (_) => MaterialPageRoute(
        builder: (_) =>
            const Scaffold(body: Center(child: Text('알 수 없는 경로입니다.'))),
      ),
    );
  }
}
