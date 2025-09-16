// lib/models/resource.dart
// v1.0.1 | Resource DTO: id null-safe, map 정합성

class ResourceFile {
  final String id;
  final String nodeId; // curriculum_node_id
  final String? title; // 표시용 제목(옵션)
  final String filename; // 원본 파일명
  final String? mimeType;
  final int? sizeBytes;
  final String storageBucket;
  final String storagePath; // 버킷 내부 경로
  final DateTime? createdAt;

  const ResourceFile({
    required this.id,
    required this.nodeId,
    this.title,
    required this.filename,
    this.mimeType,
    this.sizeBytes,
    required this.storageBucket,
    required this.storagePath,
    this.createdAt,
  });

  factory ResourceFile.fromMap(Map<String, dynamic> m) {
    return ResourceFile(
      id: (m['id'] ?? '').toString(), // ← null → '' 로 통일
      nodeId: (m['curriculum_node_id'] ?? '').toString(),
      title: m['title']?.toString(),
      filename: (m['filename'] ?? '').toString(),
      mimeType: m['mime_type']?.toString(),
      sizeBytes: m['size_bytes'] is int
          ? m['size_bytes'] as int
          : int.tryParse('${m['size_bytes']}'),
      storageBucket: (m['storage_bucket'] ?? '').toString(),
      storagePath: (m['storage_path'] ?? '').toString(),
      createdAt: m['created_at'] != null
          ? DateTime.tryParse(m['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'curriculum_node_id': nodeId,
    if (title != null) 'title': title,
    'filename': filename,
    if (mimeType != null) 'mime_type': mimeType,
    if (sizeBytes != null) 'size_bytes': sizeBytes,
    'storage_bucket': storageBucket,
    'storage_path': storagePath,
  };
}
