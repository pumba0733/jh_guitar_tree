// lib/screens/home/admin_home_screen.dart
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';

class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService();
    return Scaffold(
      appBar: AppBar(
        title: const Text('관리자 홈'),
        actions: [
          IconButton(
            onPressed: () async {
              await auth.signOutAll();
              if (context.mounted) {
                Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
              }
            },
            icon: const Icon(Icons.logout),
            tooltip: '로그아웃',
          )
        ],
      ),
      body: Center(
        child: Wrap(
          spacing: 12, runSpacing: 12,
          children: [
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.manageStudents),
              icon: const Icon(Icons.people),
              label: const Text('학생 관리'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.manageTeachers),
              icon: const Icon(Icons.school),
              label: const Text('강사 관리'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.manageKeywords),
              icon: const Icon(Icons.label),
              label: const Text('키워드 관리'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.logs),
              icon: const Icon(Icons.list),
              label: const Text('로그'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.export),
              icon: const Icon(Icons.download),
              label: const Text('백업'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pushNamed(context, AppRoutes.import),
              icon: const Icon(Icons.upload),
              label: const Text('복원'),
            ),
          ],
        ),
      ),
    );
  }
}
