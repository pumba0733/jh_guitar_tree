// lib/models/curriculum.dart
// v1.39.0 | 커리큘럼 모델: Node / Assignment / Progress DTO

class CurriculumNode {
  final String id;
  final String? parentId;
  final String type; // 'category' | 'file'
  final String title;
  final String? fileUrl;
  final int order;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const CurriculumNode({
    required this.id,
    this.parentId,
    required this.type,
    required this.title,
    this.fileUrl,
    this.order = 0,
    this.createdAt,
    this.updatedAt,
  });

  factory CurriculumNode.fromMap(Map<String, dynamic> m) {
    return CurriculumNode(
      id: '${m['id']}',
      parentId: m['parent_id']?.toString(),
      type: (m['type'] ?? 'category').toString(),
      title: (m['title'] ?? '').toString(),
      fileUrl: m['file_url']?.toString(),
      order: (m['order'] ?? 0) as int,
      createdAt: m['created_at'] != null
          ? DateTime.tryParse(m['created_at'].toString())
          : null,
      updatedAt: m['updated_at'] != null
          ? DateTime.tryParse(m['updated_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'parent_id': parentId,
    'type': type,
    'title': title,
    'file_url': fileUrl,
    'order': order,
  };

  CurriculumNode copyWith({
    String? id,
    String? parentId,
    String? type,
    String? title,
    String? fileUrl,
    int? order,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CurriculumNode(
      id: id ?? this.id,
      parentId: parentId ?? this.parentId,
      type: type ?? this.type,
      title: title ?? this.title,
      fileUrl: fileUrl ?? this.fileUrl,
      order: order ?? this.order,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class CurriculumAssignment {
  final String id;
  final String studentId;
  final String curriculumNodeId;
  final List<String>? path; // jsonb array
  final String? filePath; // storage internal path (optional)
  final DateTime? createdAt;

  const CurriculumAssignment({
    required this.id,
    required this.studentId,
    required this.curriculumNodeId,
    this.path,
    this.filePath,
    this.createdAt,
  });

  factory CurriculumAssignment.fromMap(Map<String, dynamic> m) {
    final raw = m['path'];
    List<String>? path;
    if (raw is List) {
      path = raw.map((e) => e.toString()).toList();
    }
    return CurriculumAssignment(
      id: '${m['id']}',
      studentId: '${m['student_id']}',
      curriculumNodeId: '${m['curriculum_node_id']}',
      path: path,
      filePath: m['file_path']?.toString(),
      createdAt: m['created_at'] != null
          ? DateTime.tryParse(m['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'student_id': studentId,
    'curriculum_node_id': curriculumNodeId,
    if (path != null) 'path': path,
    if (filePath != null) 'file_path': filePath,
  };
}

/// 학생 진도 Progress DTO (별도 테이블 기반; 없으면 fallback)
class NodeProgress {
  final String studentId;
  final String nodeId;
  final bool isDone;
  final DateTime? updatedAt;

  const NodeProgress({
    required this.studentId,
    required this.nodeId,
    required this.isDone,
    this.updatedAt,
  });

  factory NodeProgress.fromMap(Map<String, dynamic> m) => NodeProgress(
    studentId: '${m['student_id']}',
    nodeId: '${m['curriculum_node_id']}',
    isDone: (m['is_done'] ?? false) == true,
    updatedAt: m['updated_at'] != null
        ? DateTime.tryParse(m['updated_at'].toString())
        : null,
  );

  Map<String, dynamic> toMap() => {
    'student_id': studentId,
    'curriculum_node_id': nodeId,
    'is_done': isDone,
  };
}
