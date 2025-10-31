// lib/main.dart — v1.58.8 (빌드 안정화용 최소본)
// A안 기준: 오디오는 SoundTouch 네이티브/FFI(별도 화면/서비스에서 제어), 비디오는 media_kit_video.
// 여기서는 앱 부팅/창 세팅/Supabase/Hive/에러 핸들러만 유지한다.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'supabase/supabase_options.dart';
import 'services/auth_service.dart';

import 'package:window_manager/window_manager.dart';
import 'packages/smart_media_player/audio/engine_soundtouch_ffi.dart'
    show SoundTouchProbe;

Future<void> _initDesktopWindow() async {
  if (kIsWeb) return;
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;

  await windowManager.ensureInitialized();

  const initSize = Size(1280, 840);
  const minSize = Size(1024, 720);

  final opts = const WindowOptions(
    size: initSize,
    minimumSize: minSize,
    center: true,
  );

  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();

  // 창 세팅은 비동기 (대기하지 않아도 됨)
  unawaited(_initDesktopWindow());

  // 전역 에러 핸들러
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
  };
  binding.platformDispatcher.onError = (Object error, StackTrace stack) {
    debugPrint('Uncaught platform error: $error\n$stack');
    return true;
  };

  await Hive.initFlutter();

  SupabaseOptions.ensureConfigured();
  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    anonKey: SupabaseOptions.supabaseAnonKey,
    debug: false,
  );

  final supa = Supabase.instance.client;

  // 익명 로그인 (기존 로직)
  if (supa.auth.currentUser == null) {
    try {
      await supa.auth.signInAnonymously();
    } catch (e) {
      debugPrint('anonymous sign-in failed: $e');
    }
  }

  // 부팅 시 부트스트랩 RPC들 (기존 로직)
  final initialEmail = supa.auth.currentUser?.email;
  if (initialEmail != null && initialEmail.isNotEmpty) {
    try {
      await supa.rpc(
        'upsert_teacher_min',
        params: {
          'p_email': initialEmail,
          'p_name': initialEmail.split('@').first,
          'p_is_admin': null,
        },
      );
    } catch (e) {
      debugPrint('bootstrap upsert_teacher_min error: $e');
    }
    try {
      await supa.rpc(
        'sync_auth_user_id_by_email',
        params: {'p_email': initialEmail},
      );
    } catch (e) {
      debugPrint('bootstrap sync_auth_user_id_by_email error: $e');
    }
    try {
      await AuthService().restoreLinkedIdentities();
    } catch (e) {
      debugPrint('bootstrap restoreLinkedIdentities error: $e');
    }
  }

  // 세션 리스너 (기존 로직)
  supa.auth.onAuthStateChange.listen((state) async {
    final event = state.event;
    final email = state.session?.user.email ?? '';
    if (email.isEmpty) return;
    if (event != AuthChangeEvent.signedIn &&
        event != AuthChangeEvent.tokenRefreshed) {
      return;
    }

    try {
      await supa.rpc(
        'upsert_teacher_min',
        params: {
          'p_email': email,
          'p_name': email.split('@').first,
          'p_is_admin': null,
        },
      );
    } catch (e) {
      debugPrint('listener upsert_teacher_min error: $e');
    }

    try {
      await supa.rpc('sync_auth_user_id_by_email', params: {'p_email': email});
    } catch (e) {
      debugPrint('listener sync_auth_user_id_by_email error: $e');
    }

    try {
      await AuthService().restoreLinkedIdentities();
    } catch (e) {
      debugPrint('listener restoreLinkedIdentities error: $e');
    }
  });

  runApp(const App());
}
