// lib/services/supabase_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// 공용 SupabaseClient 접근 헬퍼
class SupabaseService {
  SupabaseService._();
  static final SupabaseClient client = Supabase.instance.client;

  static Session? get currentSession => client.auth.currentSession;
  static User? get currentUser => client.auth.currentUser;
}
