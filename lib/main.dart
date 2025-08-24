import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'supabase/supabase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ Hive 초기화 (RetryQueueService에서 사용하기 전에 필수)
  await Hive.initFlutter();

  // Ensure user put real values (prevent placeholder run).
  SupabaseOptions.ensureConfigured();

  await Supabase.initialize(
    url: SupabaseOptions.supabaseUrl,
    anonKey: SupabaseOptions.supabaseAnonKey,
    debug: false,
  );

  runApp(const App());
}
