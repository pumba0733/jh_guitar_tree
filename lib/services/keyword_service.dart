// lib/services/keyword_service.dart
// v1.38.0 | feedback_keywords 연동 고도화 + 캐시TTL + 안전파싱 + 검색 지원
// - fetchCategories({force})
// - fetchItemsByCategory(category, {force})
// - fetchAllItems({force})
// - searchItems(query, {force})
// - invalidateCache()
//
// 요구 스키마: public.feedback_keywords(category text, items jsonb[])
//
// 사용 예:
// final cats = await KeywordService().fetchCategories();
// final rhythm = await KeywordService().fetchItemsByCategory('리듬');
// final hits = await KeywordService().searchItems('코드');
// KeywordService().invalidateCache(); // 관리자 편집 후 캐시 비우기

import 'dart:convert' show jsonDecode;

import 'package:supabase_flutter/supabase_flutter.dart';
import '../supabase/supabase_tables.dart';

class KeywordItem {
  final String text; // UI 표시용
  final String value; // 저장/검색용(없으면 text와 동일)

  const KeywordItem(this.text, this.value);

  factory KeywordItem.fromDynamic(dynamic raw) {
    // items가 ["문자열", {"text": "...", "value":"..."}] 혼재 가능
    if (raw is String) {
      final t = raw.trim();
      return KeywordItem(t, t);
    }
    if (raw is Map) {
      final m = Map<String, dynamic>.from(raw);
      final text = (m['text'] ?? m['value'] ?? '').toString().trim();
      final value = (m['value'] ?? m['text'] ?? '').toString().trim();
      final normText = text.isEmpty ? value : text;
      final normValue = value.isEmpty ? normText : value;
      return KeywordItem(normText, normValue);
    }
    // 알 수 없는 타입은 빈 값 방지용 기본값
    return const KeywordItem('', '');
  }

  Map<String, dynamic> toJson() => {'text': text, 'value': value};

  // 소문자/공백정리 비교 키
  String get _lcText => text.toLowerCase().trim();
  String get _lcValue => value.toLowerCase().trim();

  bool matches(String q) {
    final term = q.toLowerCase().trim();
    return _lcText.contains(term) || _lcValue.contains(term);
  }

  @override
  String toString() => 'KeywordItem(text: $text, value: $value)';

  // 중복 제거 정확도 향상을 위한 동등성 정의
  @override
  bool operator ==(Object other) =>
      other is KeywordItem && other.text == text && other.value == value;

  @override
  int get hashCode => Object.hash(text, value);
}

class KeywordService {
  KeywordService._();
  static final KeywordService instance = KeywordService._();
  factory KeywordService() => instance;

  final SupabaseClient _client = Supabase.instance.client;

  // ===== 메모리 캐시 + TTL =====
  List<String>? _categories;
  final Map<String, List<KeywordItem>> _byCategory = {};
  DateTime? _cacheAt;
  Duration _ttl = const Duration(minutes: 10);

  // 내부: 캐시 사용 가능 여부
  bool _useCache(bool force) {
    if (force) return false;
    if (_cacheAt == null) return false;
    final expired = DateTime.now().difference(_cacheAt!) > _ttl;
    return !expired;
  }

  // 내부: 캐시 타임스탬프 갱신
  void _touchCache() => _cacheAt = DateTime.now();

  // 내부: JSON-any → List<KeywordItem>
  List<KeywordItem> _parseItems(dynamic items) {
    final out = <KeywordItem>[];

    dynamic source = items;

    // 1) 문자열 JSON으로 오는 엣지 케이스 방어
    if (source is String) {
      try {
        final decoded = jsonDecode(source);
        source = decoded;
      } catch (_) {
        // 파싱 실패 시 빈 리스트 처리 (운영에선 jsonb 일관 유지 권장)
        source = const [];
      }
    }

    // 2) 정상 케이스: jsonb[] → List<dynamic>
    if (source is List) {
      for (final raw in source) {
        final it = KeywordItem.fromDynamic(raw);
        if (it.text.isNotEmpty) out.add(it);
      }
    }

    // 3) 중복 제거(text/value 모두 기준; ==/hashCode 활용)
    final dedup = <KeywordItem>{}..addAll(out);
    return dedup.toList(growable: false);
  }

  /// 캐시 무효화 (관리자 수정 후 버튼에 연결)
  void invalidateCache() {
    _categories = null;
    _byCategory.clear();
    _cacheAt = null;
  }

  /// 캐시 TTL 동적 조정(테스트/운영 전환용)
  void setCacheTtl(Duration ttl) {
    _ttl = ttl;
  }

  /// 카테고리 목록 가져오기
  /// - 기본: 캐시 + TTL 사용
  /// - force=true: 서버 재조회
  Future<List<String>> fetchCategories({bool force = false}) async {
    if (_categories != null && _useCache(force)) {
      return _categories!;
    }

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

    // DB 비어있으면 폴백
    _categories = set.isEmpty ? <String>['기본'] : set.toList(growable: false);
    _touchCache();
    return _categories!;
  }

  /// 특정 카테고리의 아이템 목록
  /// - 기본: 캐시 + TTL 사용
  /// - force=true: 서버 재조회
  Future<List<KeywordItem>> fetchItemsByCategory(
    String category, {
    bool force = false,
  }) async {
    // 캐시 히트
    if (_byCategory.containsKey(category) && _useCache(force)) {
      return _byCategory[category]!;
    }

    // 서버 조회
    final res = await _client
        .from(SupabaseTables.feedbackKeywords)
        .select('items')
        .eq('category', category)
        .limit(1)
        .maybeSingle();

    List<KeywordItem> list = const [];

    if (res != null) {
      final map = Map<String, dynamic>.from(res as Map);
      final dynamic items = map['items'];
      list = _parseItems(items);
    }

    // 폴백(카테고리 미존재 혹은 items 비어있음)
    if (list.isEmpty && category == '기본') {
      list = const [
        KeywordItem('박자', '박자'),
        KeywordItem('코드 전환', '코드 전환'),
        KeywordItem('리듬', '리듬'),
        KeywordItem('운지', '운지'),
        KeywordItem('스케일', '스케일'),
        KeywordItem('톤', '톤'),
        KeywordItem('댐핑', '댐핑'),
      ];
    }

    _byCategory[category] = list;
    _touchCache();
    return list;
  }

  /// 전 카테고리 통합 아이템
  Future<List<KeywordItem>> fetchAllItems({bool force = false}) async {
    final cats = await fetchCategories(force: force);
    final out = <KeywordItem>[];
    for (final c in cats) {
      final items = await fetchItemsByCategory(c, force: force);
      out.addAll(items);
    }
    // 중복 제거 (==/hashCode 활용)
    final dedup = <KeywordItem>{}..addAll(out);
    return dedup.toList(growable: false);
  }

  /// 검색(클라이언트 측 필터)
  /// - PostgREST의 jsonb 내 ILIKE 한계 회피 위해 전체 아이템 로드 후 필터
  Future<List<KeywordItem>> searchItems(
    String query, {
    bool force = false,
  }) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final all = await fetchAllItems(force: force);
    return all.where((it) => it.matches(term)).toList(growable: false);
  }
}
