// lib/constants/app_env.dart
// v1.21.2 | 환경설정 상수 (LLM 엔드포인트/키 + 재시도 주기)

class AppEnv {
  /// 실행 모드: dev | prod
  static const String appMode = String.fromEnvironment(
    'APP_MODE',
    defaultValue: 'dev',
  );

  /// 재시도 큐 interval(sec)
  /// --dart-define=RETRY_INTERVAL=45 로 재정의 가능
  static const int retryIntervalSeconds = int.fromEnvironment(
    'RETRY_INTERVAL',
    defaultValue: 30,
  );

  /// LLM API 엔드포인트 (예: https://your-llm.example.com/summarize)
  /// --dart-define=LLM_ENDPOINT=... 로 재정의 가능
  static const String llmEndpoint = String.fromEnvironment(
    'LLM_ENDPOINT',
    defaultValue: 'http://localhost:8787/summarize',
  );

  /// LLM API 키
  /// --dart-define=LLM_API_KEY=... 로 재정의 가능
  static const String llmApiKey = String.fromEnvironment(
    'LLM_API_KEY',
    defaultValue: '',
  );
}
