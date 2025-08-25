// lib/services/keyword_service.dart
// v1.23.1 | feedback_keywords 연동 + 메모리 캐시 + 강제재조회(force)
// - fetchCategories({force})
// - fetchItemsByCategory(category, {force})
// - fetchAllItems({force})
// - invalidateCache()  ← 관리자 수정 후 버튼에 연결
//
// 요구 스키마: public.feedback_keywords(category text, items jsonb[])
//
// 사용 예:
// final cats = await KeywordService().fetchCategories();
// final rhythm = await KeywordService().fetchItemsByCategory('리듬');
// KeywordService().invalidateCache(); // 관리자 편집 후 캐시 비우기

import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase/supabase_tables.dart';

class KeywordItem {
  final String text; // UI 표시용
  final String value; // 저장/검색용(없으면 text와 동일)
  const KeywordItem(this.text, this.value);

  @override
  String toString() => 'KeywordItem(text: $text, value: $value)';
}

class KeywordService {
  KeywordService._();
  static final KeywordService instance = KeywordService._();
  factory KeywordService() => instance;

  final SupabaseClient _client = Supabase.instance.client;

  // ===== 메모리 캐시 =====
  List<String>? _categories;
  final Map<String, List<KeywordItem>> _byCategory = {};

  /// 카테고리 목록 가져오기
  /// - 기본: 메모리 캐시 사용
  /// - force=true: 서버에서 다시 읽고 캐시 갱신
  Future<List<String>> fetchCategories({bool force = false}) async {
    if (!force && _categories != null) return _categories!;

    final res = await _client
        .from(SupabaseTables.feedbackKeywords)
        .select('category')
        .order('category');

    final set = <String>{};
    for (final row in (res as List)) {
      final m = Map<String, dynamic>.from(row as Map);
      final c = (m['category'] ?? '').toString().trim();
      if (c.isNotEmpty) set.add(c);
    }
    _categories = set.toList();
    return _categories!;
  }

  /// 특정 카테고리의 아이템 목록 가져오기
  /// - 기본: 메모리 캐시 사용
  /// - force=true: 서버에서 다시 읽고 캐시 갱신
  Future<List<KeywordItem>> fetchItemsByCategory(
    String category, {
    bool force = false,
  }) async {
    if (!force && _byCategory.containsKey(category)) {
      return _byCategory[category]!;
    }

    final res = await _client
        .from(SupabaseTables.feedbackKeywords)
        .select('items')
        .eq('category', category)
        .limit(1)
        .maybeSingle();

    final list = <KeywordItem>[];
    if (res != null) {
      final map = Map<String, dynamic>.from(res as Map);
      final items = map['items'];
      if (items is List) {
        for (final it in items) {
          if (it is Map) {
            final mm = Map<String, dynamic>.from(it);
            final text = (mm['text'] ?? mm['value'] ?? '').toString().trim();
            final value = (mm['value'] ?? mm['text'] ?? '').toString().trim();
            if (text.isNotEmpty) {
              list.add(KeywordItem(text, value.isEmpty ? text : value));
            }
          } else if (it is String) {
            final t = it.trim();
            if (t.isNotEmpty) list.add(KeywordItem(t, t));
          }
        }
      }
    }

    _byCategory[category] = list;
    return list;
  }

  /// 전 카테고리 통합 아이템 목록
  /// - 각 카테고리 순차 조회(캐시 사용)
  /// - force=true: 카테고리/아이템 모두 서버 재조회
  Future<List<KeywordItem>> fetchAllItems({bool force = false}) async {
    final cats = await fetchCategories(force: force);
    final out = <KeywordItem>[];
    for (final c in cats) {
      out.addAll(await fetchItemsByCategory(c, force: force));
    }
    return out;
  }

  /// 메모리 캐시 무효화 (관리자 수정 후 버튼에 연결)
  void invalidateCache() {
    _categories = null;
    _byCategory.clear();
  }
}
