// lib/main.dart — v1.51.1 | Zone mismatch 종결 + PlatformDispatcher 미정의 해결
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'supabase/supabase_options.dart';

Future<void> main() async {
  // 바인딩 획득(이 인스턴스를 통해 platformDispatcher 접근)
  final binding = WidgetsFlutterBinding.ensureInitialized();

  // 전역 에러 핸들러(Flutter 프레임워크)
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    // TODO: 필요하면 여기서 Sentry/Crashlytics 연동
  };

  // 전역 에러 핸들러(플랫폼/비동기): PlatformDispatcher는 binding 경유
  binding.platformDispatcher.onError = (Object error, StackTrace stack) {
    // ignore: avoid_print
    print('Uncaught platform error: $error\n$stack');
    // TODO: 필요하면 여기서 Sentry/Crashlytics 연동
    return true; // 에러를 우리가 처리했다고 명시
  };

  // ✅ Hive 초기화 (RetryQueueService 등에서 사용하기 전에 필수)
  await Hive.initFlutter();

  // ✅ Supabase 옵션 확인(placeholder 방지)
  SupabaseOptions.ensureConfigured();

  // ✅ Supabase 초기화
  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    anonKey: SupabaseOptions.supabaseAnonKey,
    debug: false,
  );

  // 같은 Zone에서 바로 실행 (runZonedGuarded 제거)
  runApp(const App());
}
