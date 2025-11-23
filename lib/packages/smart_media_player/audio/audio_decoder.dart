import 'dart:io';
import 'dart:typed_data';

class AudioDecoder {
  /// input: mp3/mp4/wav → Float32List PCM
  static Future<Float32List> decodeToFloat32(String path) async {
    // 1) mp3/mp4 → wav 변환
    final wavPath = await _convertToWav(path);

    // 2) wav → float32
    return _decodeWav(File(wavPath));
  }

  static Future<String> _convertToWav(String path) async {
    final out = '$path.pcm.wav';

    final result = await Process.run('ffmpeg', [
      '-y',
      '-i',
      path,
      '-ac',
      '2',
      '-ar',
      '44100',
      '-f',
      'f32le',
      out,
    ]);

    if (result.exitCode != 0) {
      throw Exception('wav 변환 실패: ${result.stderr}');
    }

    return out;
  }

  static Future<Float32List> _decodeWav(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.length < 44) {
      throw Exception("Invalid WAV: too small");
    }

    // WAV header skip, get to PCM body
    int dataOffset = -1;
    for (int i = 12; i < bytes.length - 8; i++) {
      if (bytes[i] == 0x64 &&
          bytes[i + 1] == 0x61 &&
          bytes[i + 2] == 0x74 &&
          bytes[i + 3] == 0x61) {
        dataOffset = i + 8;
        break;
      }
    }
    if (dataOffset < 0) throw Exception("WAV data chunk not found");

    final pcmBytes = bytes.sublist(dataOffset);
    return pcmBytes.buffer.asFloat32List(
      pcmBytes.offsetInBytes,
      pcmBytes.length ~/ 4,
    );
  }
}
