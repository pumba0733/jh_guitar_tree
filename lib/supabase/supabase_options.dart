// ⚠️ 여기에 너의 Supabase 프로젝트 값을 넣어야 실제 로그인 동작함.
class SupabaseOptions {
  // 예시: https://abcdxyz.supabase.co
  static const String supabaseUrl = 'https://qvqtzuvuwjhfrfexjnnv.supabase.co';

  // 예시: eyJhbGciOiJIUzI1NiIs...
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF2cXR6dXZ1d2poZnJmZXhqbm52Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTU2NjM0MDksImV4cCI6MjA3MTIzOTQwOX0.IQ1X3rAnY4L5w5ZUqVAlTDw2VJLHhrCmqXbkMsTe2RQ';

  static void ensureConfigured() {
    if (supabaseUrl.startsWith('PUT_') || supabaseAnonKey.startsWith('PUT_')) {
      throw Exception(
        'SupabaseOptions: supabaseUrl/anonKey를 먼저 설정하세요. '
        'lib/supabase/supabase_options.dart 확인!',
      );
    }
  }
}
