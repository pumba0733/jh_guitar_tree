// lib/models/lesson_attachment.dart
// v1.65 | lesson_attachments 테이블 1:1 DTO

class LessonAttachment {
  final String id;
  final String lessonId;

  /// 'xsc' | 'file'
  final String type;

  final String storageBucket; // lesson_attachments
  final String storageKey; // 버킷 내 key (경로)
  final String? originalFilename;

  // v1.65 메타
  final String? mp3Hash; // 동일 음원 매칭용(옵션)
  final String? xscStoragePath; // student_xsc/<sid>/<hash>/current.xsc
  final String? mediaName; // 표시용(옵션)
  final DateTime? xscUpdatedAt;

  final DateTime? createdAt;

  const LessonAttachment({
    required this.id,
    required this.lessonId,
    required this.type,
    required this.storageBucket,
    required this.storageKey,
    this.originalFilename,
    this.mp3Hash,
    this.xscStoragePath,
    this.mediaName,
    this.xscUpdatedAt,
    this.createdAt,
  });

  factory LessonAttachment.fromMap(Map<String, dynamic> m) {
    return LessonAttachment(
      id: (m['id'] ?? '').toString(),
      lessonId: (m['lesson_id'] ?? '').toString(),
      type: (m['type'] ?? '').toString(),
      storageBucket: (m['storage_bucket'] ?? '').toString(),
      storageKey: (m['storage_key'] ?? '').toString(),
      originalFilename: m['original_filename']?.toString(),
      mp3Hash: m['mp3_hash']?.toString(),
      xscStoragePath: m['xsc_storage_path']?.toString(),
      mediaName: m['media_name']?.toString(),
      xscUpdatedAt: m['xsc_updated_at'] != null
          ? DateTime.tryParse(m['xsc_updated_at'].toString())
          : null,
      createdAt: m['created_at'] != null
          ? DateTime.tryParse(m['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'lesson_id': lessonId,
    'type': type,
    'storage_bucket': storageBucket,
    'storage_key': storageKey,
    if (originalFilename != null) 'original_filename': originalFilename,
    if (mp3Hash != null) 'mp3_hash': mp3Hash,
    if (xscStoragePath != null) 'xsc_storage_path': xscStoragePath,
    if (mediaName != null) 'media_name': mediaName,
    if (xscUpdatedAt != null) 'xsc_updated_at': xscUpdatedAt!.toIso8601String(),
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
  };
}
