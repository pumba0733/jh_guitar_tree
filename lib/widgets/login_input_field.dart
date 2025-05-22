// 📄 lib/widgets/login_input_field.dart

import 'package:flutter/material.dart';

class LoginInputField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final TextInputType keyboardType;
  final bool obscureText;
  final int? maxLength;
  final void Function(String)? onSubmitted;

  const LoginInputField({
    super.key,
    required this.controller,
    required this.hintText,
    this.keyboardType = TextInputType.text,
    this.obscureText = false,
    this.maxLength,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      maxLength: maxLength,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hintText,
        border: const OutlineInputBorder(),
        counterText: "",
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
      ),
    );
  }
}
