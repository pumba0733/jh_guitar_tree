import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/widgets/staff_portal/portal_action_button.dart';

class PortalActionGrid extends StatelessWidget {
  final String role;
  const PortalActionGrid({super.key, required this.role});

  bool get isAdmin => role == 'admin';

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
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
            icon: Icons.summarize,
            onTap: () {
              // TODO: Navigator.pushNamed(context, '/lesson_summary');
            },
          ),
          if (isAdmin)
            PortalActionButton(
              title: '💬 키워드 관리',
              icon: Icons.label,
              onTap: () {
                // TODO: Navigator.pushNamed(context, '/manage_keywords');
              },
            ),
          PortalActionButton(
            title: '📦 백업',
            icon: Icons.backup,
            onTap: () {
              // TODO: Navigator.pushNamed(context, '/export');
            },
          ),
          if (isAdmin)
            PortalActionButton(
              title: '📥 복원',
              icon: Icons.restore,
              onTap: () {
                // TODO: Navigator.pushNamed(context, '/import');
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
              title: '👥 강사 관리',
              icon: Icons.group,
              onTap: () {
                // TODO: Navigator.pushNamed(context, '/manage_teachers');
              },
            ),
          PortalActionButton(
            title: '🔐 비밀번호 변경',
            icon: Icons.lock,
            onTap: () {
              // TODO: Navigator.pushNamed(context, '/change_password');
            },
          ),
        ],
      ),
    );
  }
}
