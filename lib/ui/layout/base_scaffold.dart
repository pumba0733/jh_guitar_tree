// 📄 lib/ui/layout/base_scaffold.dart

import 'package:flutter/material.dart';

class BaseScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget>? actions;

  const BaseScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            onPressed: () {
              // 설정 화면으로 이동
            },
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: Center(child: child),
    );
  }
}
