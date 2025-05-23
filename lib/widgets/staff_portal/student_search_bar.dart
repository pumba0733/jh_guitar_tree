import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // ✅ 추가됨

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
      child: Focus(
        onKeyEvent: (node, event) {
          // ✅ deprecated된 onKey → onKeyEvent로 교체
          if (event.logicalKey == LogicalKeyboardKey.escape &&
              event is KeyDownEvent) {
            controller.clear();
            onChanged('');
            onRefresh();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: isAdmin ? '전체 학생 검색' : '담당 학생 검색',
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                controller.clear();
                onChanged('');
                onRefresh();
              },
            ),
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
