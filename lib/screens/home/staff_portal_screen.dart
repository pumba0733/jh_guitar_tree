import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/services/student_service.dart';
import 'package:jh_guitar_tree/services/auth_service.dart';
import 'package:jh_guitar_tree/dialogs/student_edit_dialog.dart';
import 'package:jh_guitar_tree/widgets/staff_portal/portal_action_grid.dart';
import 'package:jh_guitar_tree/widgets/staff_portal/student_list_tile.dart';
import 'package:jh_guitar_tree/widgets/staff_portal/student_search_bar.dart';

class StaffPortalScreen extends StatefulWidget {
  const StaffPortalScreen({super.key});

  @override
  State<StaffPortalScreen> createState() => _StaffPortalScreenState();
}

class _StaffPortalScreenState extends State<StaffPortalScreen> {
  final StudentService _studentService = StudentService();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  void refreshList() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = AuthService().isAdmin;
    final role = AuthService().currentUserRole ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('강사/관리자 포털'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '학생 등록',
            onPressed:
                () => showDialog(
                  context: context,
                  builder:
                      (context) => StudentEditDialog(
                        isAdmin: isAdmin,
                        onRefresh: refreshList,
                        role: role,
                      ),
                ),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              children: [
                StudentSearchBar(
                  isAdmin: isAdmin,
                  role: role,
                  onRefresh: refreshList,
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() => _searchQuery = value.trim());
                  },
                ),
                Expanded(
                  child: StreamBuilder<List<Student>>(
                    stream: _studentService.getAccessibleStudents(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (!snapshot.hasData || snapshot.data!.isEmpty) {
                        return const Center(child: Text('등록된 학생이 없습니다.'));
                      }

                      final filtered =
                          snapshot.data!
                              .where(
                                (s) =>
                                    s.name.contains(_searchQuery) ||
                                    s.phoneSuffix.contains(_searchQuery),
                              )
                              .toList();

                      return ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          return StudentListTile(
                            student: filtered[index],
                            onRefresh: refreshList,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(flex: 1, child: PortalActionGrid(role: role)),
        ],
      ),
    );
  }
}
