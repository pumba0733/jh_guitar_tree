import 'package:flutter/material.dart';
import 'package:jh_guitar_tree/models/student.dart';
import 'package:jh_guitar_tree/models/teacher.dart';
import 'package:jh_guitar_tree/services/student_service.dart';
import 'package:jh_guitar_tree/widgets/staff_portal/portal_action_grid.dart';
import 'package:jh_guitar_tree/widgets/staff_portal/student_list_tile.dart';
import 'package:jh_guitar_tree/widgets/staff_portal/student_search_bar.dart';

class StaffPortalScreen extends StatefulWidget {
  final Teacher teacher;

  const StaffPortalScreen({super.key, required this.teacher});

  @override
  State<StaffPortalScreen> createState() => _StaffPortalScreenState();
}

class _StaffPortalScreenState extends State<StaffPortalScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  List<Student> _allStudents = [];

  void refreshList() {
    setState(() {}); // 간단한 리빌드 트리거
  }

  Future<void> fetchStudents() async {
    final service = StudentService();
    final students = await service.getAllStudents();

    students.sort((a, b) => a.name.compareTo(b.name));
    setState(() {
      _allStudents = students;
    });
  }

  @override
  void initState() {
    super.initState();
    fetchStudents();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = widget.teacher.role == 'admin';

    List<Student> filtered =
        _searchQuery.isEmpty
            ? _allStudents
            : _allStudents.where((s) => s.name.contains(_searchQuery)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('강사 포털')),
      body: Row(
        children: [
          // 좌측 학생 목록
          Expanded(
            flex: 2,
            child: Column(
              children: [
                StudentSearchBar(
                  isAdmin: isAdmin,
                  role: widget.teacher.role,
                  onRefresh: fetchStudents,
                  controller: _searchController,
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      return StudentListTile(
                        student: filtered[index],
                        onRefresh: fetchStudents,
                        allStudents: _allStudents,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          // 우측 기능 버튼
          Expanded(flex: 1, child: PortalActionGrid(teacher: widget.teacher)),
        ],
      ),
    );
  }
}
