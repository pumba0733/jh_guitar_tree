import 'package:flutter/material.dart';

class StudentSearchBar extends StatelessWidget {
  final bool isAdmin;
  final String role;
  final VoidCallback onRefresh;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const StudentSearchBar({
    super.key,
    required this.isAdmin,
    required this.role,
    required this.onRefresh,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: isAdmin ? '전체 학생 검색' : '담당 학생 검색',
          suffixIcon: IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () {
              controller.clear();
              onChanged('');
              onRefresh(); // 새로고침 트리거
            },
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}
