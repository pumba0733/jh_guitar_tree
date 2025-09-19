// lib/main.dart — v1.58.1 | 초기화/세션리스너 정리 + 세션 복원 호출
// - 중복 onAuthStateChange 리스너 제거, 단일 리스너로 통합
// - 부팅 직후/로그인·토큰갱신 시 upsert_teacher_min + sync_auth_user_id_by_email
// - 각 시점마다 AuthService.restoreLinkedIdentities() 호출로 교사 상태 재결합

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'supabase/supabase_options.dart';
import 'services/auth_service.dart';

Future<void> main() async {
  // 바인딩 획득
  final binding = WidgetsFlutterBinding.ensureInitialized();

  // 전역 에러 핸들러(Flutter 프레임워크)
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    // TODO: Sentry/Crashlytics 연동 지점
  };

  // 전역 에러 핸들러(플랫폼/비동기)
  binding.platformDispatcher.onError = (Object error, StackTrace stack) {
    // ignore: avoid_print
    print('Uncaught platform error: $error\n$stack');
    // TODO: Sentry/Crashlytics 연동 지점
    return true;
  };

  // ✅ Hive 초기화
  await Hive.initFlutter();

  // ✅ Supabase 옵션 확인
  SupabaseOptions.ensureConfigured();

  // ✅ Supabase 초기화
  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    anonKey: SupabaseOptions.supabaseAnonKey,
    debug: false,
  );

  final supa = Supabase.instance.client;
  if (supa.auth.currentUser == null) {
    try {
      await supa.auth.signInAnonymously();
    } catch (e) {
      // ignore: avoid_print
      print('anonymous sign-in failed: $e');
    }
  }

  // ✅ 부트스트랩: 앱 시작 직후 현재 세션이 있으면 1회 동기화 + 상태 복원
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
    // 🔁 세션 ↔ 교사 레코드 재결합
    try {
      await AuthService().restoreLinkedIdentities();
    } catch (e) {
      // ignore: avoid_print
      print('bootstrap restoreLinkedIdentities error: $e');
    }
  }

  // ✅ 단일 세션 리스너: 로그인 / 토큰갱신에만 반응
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
      // ignore: avoid_print
      print('listener upsert_teacher_min error: $e');
    }

    try {
      await supa.rpc('sync_auth_user_id_by_email', params: {'p_email': email});
    } catch (e) {
      // ignore: avoid_print
      print('listener sync_auth_user_id_by_email error: $e');
    }

    // 🔁 세션 ↔ 교사 레코드 재결합
    try {
      await AuthService().restoreLinkedIdentities();
    } catch (e) {
      // ignore: avoid_print
      print('listener restoreLinkedIdentities error: $e');
    }
  });

  runApp(const App());
}
