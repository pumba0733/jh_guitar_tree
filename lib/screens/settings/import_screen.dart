// lib/screens/settings/import_screen.dart
import 'package:flutter/material.dart';

class ImportScreen extends StatelessWidget {
  const ImportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('복원')),
      body: const Center(
        child: Text('JSON 복원 기능은 관리자 전용으로 후속 업데이트에서 제공됩니다.'),
      ),
    );
  }
}
