// lib/models/curriculum.dart
// v1.44.0 | 커리큘럼 모델 정합 보강
// - order 캐스팅 안전화(num→int)
// - NodeProgress: done/is_done 호환(읽기), 기록 시 'done'으로 통일

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
      order: (m['order'] is num) ? (m['order'] as num).toInt() : 0,
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

/// 학생 진도 Progress DTO (done/is_done 호환)
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
    // done 또는 is_done 둘 다 허용
    isDone: (m['done'] ?? m['is_done'] ?? false) == true,
    updatedAt: m['updated_at'] != null
        ? DateTime.tryParse(m['updated_at'].toString())
        : null,
  );

  Map<String, dynamic> toMap() => {
    'student_id': studentId,
    'curriculum_node_id': nodeId,
    // 기록은 표준 키인 'done'으로 통일
    'done': isDone,
  };
}
