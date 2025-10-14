// lib/main.dart — v1.58.7
// - 창 크기/중앙 표시: window_manager 사용 유지
// - just_audio media_kit 백엔드 초기화: macOS 명시 활성화(macOS:true)
// - print→debugPrint, 린트 정리, 기존 Supabase/Hive/세션 리스너 유지

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'supabase/supabase_options.dart';
import 'services/auth_service.dart';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:window_manager/window_manager.dart';

// ⛔️ 삭제: macOS libs 직접 import 불필요
// import 'package:media_kit_libs_macos_audio/media_kit_libs_macos_audio.dart';

Future<void> _initDesktopWindow() async {
  if (kIsWeb) return;
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;

  await windowManager.ensureInitialized();

  const initSize = Size(1280, 840);
  const minSize = Size(1024, 720);

  final opts = WindowOptions(
    size: initSize,
    minimumSize: minSize,
    center: true,
  );

  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

void _initAudioBackend() {
  // just_audio ← media_kit 백엔드 연결
  JustAudioMediaKit.protocolWhitelist = const ['file', 'https', 'http'];
  JustAudioMediaKit.pitch = true;

  // ⬇️ macOS 명시 활성화 필수
  JustAudioMediaKit.ensureInitialized(
    macOS: true,
    // windows/linux는 기본 true라 별도 지정 불필요
  );
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();

  // 데스크톱 창 먼저 세팅
  unawaited(_initDesktopWindow());

  // just_audio 백엔드 초기화
  _initAudioBackend();

  // 전역 에러 핸들러
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    // TODO: Sentry/Crashlytics 연동
  };
  binding.platformDispatcher.onError = (Object error, StackTrace stack) {
    debugPrint('Uncaught platform error: $error\n$stack');
    // TODO: Sentry/Crashlytics 연동
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

  // 익명 로그인 보정
  if (supa.auth.currentUser == null) {
    try {
      await supa.auth.signInAnonymously();
    } catch (e) {
      debugPrint('anonymous sign-in failed: $e');
    }
  }

  // 부팅 직후 세션 존재 시 1회 동기화 + 상태 복원
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

  // 단일 세션 리스너
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
