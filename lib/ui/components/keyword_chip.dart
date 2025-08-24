// lib/ui/components/keyword_chip.dart
import 'package:flutter/material.dart';

class KeywordChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const KeywordChip({super.key, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}
