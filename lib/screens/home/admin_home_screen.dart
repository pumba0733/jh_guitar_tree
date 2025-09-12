// lib/screens/home/admin_home_screen.dart
// v1.44.1 | 관리자 홈: Material 3 전환 + 아이콘/const 오류 수정 + 브라우저 바로가기
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../routes/app_routes.dart';
import 'widgets/teacher_home_body.dart';

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  bool _guarding = true;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _guard();
  }

  Future<void> _guard() async {
    try {
      final role = await AuthService().getRole();
      if (!mounted) {
        return; // 블록화
      }
      final isAdmin = role == UserRole.admin;
      setState(() {
        _isAdmin = isAdmin;
        _guarding = false;
      });
      if (!isAdmin) {
        final route = switch (role) {
          UserRole.teacher => AppRoutes.teacherHome,
          UserRole.student => AppRoutes.studentHome,
          _ => AppRoutes.login,
        };
        Navigator.of(context).pushNamedAndRemoveUntil(route, (_) => false);
      }
    } catch (_) {
      if (!mounted) {
        return; // 블록화
      }
      setState(() => _guarding = false);
    }
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = '진행',
    String cancelText = '취소',
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelText),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    if (_guarding) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('관리자 홈'),
        actions: [
          IconButton(
            onPressed: () => Navigator.pushNamed(context, AppRoutes.logs),
            icon: const Icon(Icons.list_alt),
            tooltip: '로그',
          ),
          IconButton(
            onPressed: () async {
              await AuthService().signOutAll();
              if (!context.mounted) {
                return; // 블록화
              }
              Navigator.of(
                context,
              ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
            },
            icon: const Icon(Icons.logout),
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: Column(
        children: [
          const Expanded(child: TeacherHomeBody()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    // ===== 관리 패널 =====
                    FilledButton.tonalIcon(
                      onPressed: !_isAdmin
                          ? null
                          : () => Navigator.pushNamed(
                              context,
                              AppRoutes.manageStudents,
                            ),
                      icon: const Icon(Icons.people),
                      label: const Text('학생 관리'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: !_isAdmin
                          ? null
                          : () => Navigator.pushNamed(
                              context,
                              AppRoutes.manageTeachers,
                            ),
                      icon: const Icon(Icons.school),
                      label: const Text('강사 관리'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: !_isAdmin
                          ? null
                          : () => Navigator.pushNamed(
                              context,
                              AppRoutes.manageKeywords,
                            ),
                      icon: const Icon(Icons.label),
                      label: const Text('키워드 관리'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () =>
                          Navigator.pushNamed(context, AppRoutes.logs),
                      icon: const Icon(Icons.list_alt),
                      label: const Text('로그'),
                    ),
                    FilledButton.icon(
                      onPressed: !_isAdmin
                          ? null
                          : () async {
                              final ok = await _confirm(
                                context,
                                title: '백업 실행',
                                message: '현재 데이터를 내보냅니다. 진행할까요?',
                                confirmText: '백업',
                              );
                              if (!ok || !context.mounted) {
                                return; // 블록화
                              }
                              Navigator.pushNamed(context, AppRoutes.export);
                            },
                      icon: const Icon(Icons.download),
                      label: const Text('백업'),
                    ),
                    FilledButton.icon(
                      onPressed: !_isAdmin
                          ? null
                          : () async {
                              final ok = await _confirm(
                                context,
                                title: '복원 실행',
                                message: '복원은 기존 데이터를 덮어쓸 수 있습니다. 정말 진행할까요?',
                                confirmText: '복원 진행',
                                danger: true,
                              );
                              if (!ok || !context.mounted) {
                                return; // 블록화
                              }
                              Navigator.pushNamed(
                                context,
                                AppRoutes.importData,
                              );
                            },
                      icon: const Icon(Icons.upload),
                      label: const Text('복원'),
                    ),

                    // ===== 커리큘럼 패널 =====
                    FilledButton.tonalIcon(
                      onPressed: !_isAdmin
                          ? null
                          : () => Navigator.pushNamed(
                              context,
                              AppRoutes.curriculumStudio,
                            ),
                      icon: const Icon(Icons.account_tree),
                      label: const Text('커리큘럼 스튜디오'),
                    ),
                    // ✅ 배정 진입점: 커리큘럼 브라우저
                    FilledButton.tonalIcon(
                      onPressed: !_isAdmin
                          ? null
                          : () => Navigator.pushNamed(
                              context,
                              AppRoutes.curriculumBrowser,
                            ),
                      icon: const Icon(Icons.travel_explore),
                      label: const Text('커리큘럼 브라우저'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
