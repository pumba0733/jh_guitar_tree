// lib/constants/app_env.dart
// v1.20 | 운영/개발 모드 스위치
class AppEnv {
  static const String appMode = String.fromEnvironment(
    'APP_MODE',
    defaultValue: 'dev',
  );
  static bool get isProd => appMode == 'prod';
}
