import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/teacher.dart';
import 'package:jh_guitar_tree/widgets/staff_portal/portal_action_button.dart';

class PortalActionGrid extends StatelessWidget {
  final Teacher teacher;

  const PortalActionGrid({super.key, required this.teacher});

  bool get isAdmin => teacher.role == 'admin';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 🔁 시트 동기화 상단 TextButton
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: TextButton.icon(
            onPressed: () {
              // TODO: 동기화 로직 구현
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('시트 동기화 기능은 준비 중입니다.')),
              );
            },
            icon: const Icon(Icons.sync),
            label: const Text('시트 동기화'),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: GridView.count(
            crossAxisCount: 2,
            childAspectRatio: 2.4,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            padding: const EdgeInsets.all(12),
            children: [
              PortalActionButton(
                title: '📑 커리큘럼 배정',
                icon: Icons.assignment,
                onTap: () {
                  // TODO: Navigator.pushNamed(context, '/assign_curriculum');
                },
              ),
              if (isAdmin)
                PortalActionButton(
                  title: '🌳 커리큘럼 설계',
                  icon: Icons.forest,
                  onTap: () {
                    // TODO: Navigator.pushNamed(context, '/manage_curriculum');
                  },
                ),
              PortalActionButton(
                title: '🧠 수업 요약',
                icon: Icons.analytics,
                onTap: () {
                  // TODO: Navigator.pushNamed(context, '/lesson_summary');
                },
              ),
              if (isAdmin)
                PortalActionButton(
                  title: '📥 전체 백업',
                  icon: Icons.backup,
                  onTap: () {
                    // TODO: Navigator.pushNamed(context, '/export');
                  },
                ),
              if (isAdmin)
                PortalActionButton(
                  title: '📜 로그 보기',
                  icon: Icons.history,
                  onTap: () {
                    // TODO: Navigator.pushNamed(context, '/logs');
                  },
                ),
              if (isAdmin)
                PortalActionButton(
                  title: '👤 강사 관리',
                  icon: Icons.supervisor_account,
                  onTap: () {
                    // TODO: Navigator.pushNamed(context, '/manage_teachers');
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
