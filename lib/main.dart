import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'supabase/supabase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Supabase 옵션 확인 (placeholder 방지)
  SupabaseOptions.ensureConfigured();

  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    anonKey: SupabaseOptions.supabaseAnonKey,
    debug: false,
  );

  runApp(const App()); // ✅ GuitarTreeApp → App 로 수정
}
