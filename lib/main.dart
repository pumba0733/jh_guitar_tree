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

  final supa = Supabase.instance.client;
  supa.auth.onAuthStateChange.listen((evt) async {
    final email = evt.session?.user.email;
    if (email == null || email.isEmpty) return;

    await supa.rpc(
      'upsert_teacher_min',
      params: {
        'p_email': email,
        'p_name': email.split('@').first,
        'p_is_admin': null,
      },
    );

    await supa.rpc('sync_auth_user_id_by_email', params: {'p_email': email});
  });

  // ✅ 부트스트랩: 앱 시작 직후 현재 세션이 있으면 1회 동기화
  final initialEmail = supa.auth.currentUser?.email;
  if (initialEmail != null && initialEmail.isNotEmpty) {
    try {
      await supa.rpc(
        'upsert_teacher_min',
        params: {
          'p_email': initialEmail,
          'p_name': initialEmail.split('@').first,
          'p_is_admin': null, // 운영에선 null 유지
        },
      );
    } catch (e) {
      // ignore: avoid_print
      print('bootstrap upsert_teacher_min error: $e');
    }
    try {
      await supa.rpc(
        'sync_auth_user_id_by_email',
        params: {'p_email': initialEmail},
      );
    } catch (e) {
      // ignore: avoid_print
      print('bootstrap sync_auth_user_id_by_email error: $e');
    }
  }

  // ✅ 상태 변화 리스너: 로그인/토큰갱신 때만 동기화 (로그아웃 등은 무시)
  supa.auth.onAuthStateChange.listen((state) async {
    final event = state.event; // AuthChangeEvent
    final session = state.session; // Session?
    final email = session?.user.email ?? '';

    // 필요 이벤트만 처리
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
      // ignore: avoid_print
      print('listener upsert_teacher_min error: $e');
    }

    try {
      await supa.rpc('sync_auth_user_id_by_email', params: {'p_email': email});
    } catch (e) {
      // ignore: avoid_print
      print('listener sync_auth_user_id_by_email error: $e');
    }
  });

  // 같은 Zone에서 바로 실행 (runZonedGuarded 제거)
  runApp(const App());
}
