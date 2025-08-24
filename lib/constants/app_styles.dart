// lib/constants/app_styles.dart
import 'package:flutter/material.dart';

class AppStyles {
  static const smallGap = SizedBox(height: 8);
  static const midGap = SizedBox(height: 12);
  static const bigGap = SizedBox(height: 20);

  static InputDecoration input(String label, {String? hint}) => InputDecoration(
    labelText: label,
    hintText: hint,
  );
}
