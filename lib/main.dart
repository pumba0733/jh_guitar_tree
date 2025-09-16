import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'supabase/supabase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ Hive 초기화 (RetryQueueService 등에서 사용하기 전에 필수)
  await Hive.initFlutter();

  // ✅ Supabase 옵션이 실제 값인지 확인 (placeholder 실행 방지)
  SupabaseOptions.ensureConfigured();

  // ✅ Supabase 초기화
  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    anonKey: SupabaseOptions.supabaseAnonKey,
    debug: false,
  );

  // ✅ (선택) 전체 에러 가드 — 개발 중 콘솔로 표준화 출력
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
  };
  runZonedGuarded(
    () {
      runApp(const App());
    },
    (error, stack) {
      // ignore: avoid_print
      print('Uncaught zone error: $error\n$stack');
    },
  );
}
