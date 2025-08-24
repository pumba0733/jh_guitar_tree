// lib/models/keyword.dart
class KeywordCategory {
  final String id;
  final String category;
  final List<String> items;
  const KeywordCategory({required this.id, required this.category, required this.items});

  factory KeywordCategory.fromMap(Map<String, dynamic> m) {
    final raws = (m['items'] as List?) ?? const [];
    final items = raws.map((e) {
      if (e is Map && e['text'] != null) return '${e['text']}';
      return '$e';
    }).toList();
    return KeywordCategory(id: m['id'] as String, category: m['category'] as String, items: items);
  }
}
