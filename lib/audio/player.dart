import 'package:just_audio/just_audio.dart';

/// Toca um arquivo por vez, do começo ao fim.
///
/// Um player só, reusado: dois players seriam duas vozes ao mesmo tempo, que é
/// exatamente o que a fila FIFO existe para impedir.
class SegmentPlayer {
  final _player = AudioPlayer();

  /// Completa quando o segmento termina. A PlaybackQueue faz `await` nisto, e
  /// é esse await que mantém a fila serial.
  Future<void> play(String filePath) async {
    await _player.setFilePath(filePath);
    await _player.play();
    await _player.stop();
  }

  Future<void> interrupt() => _player.stop();

  Future<void> dispose() => _player.dispose();
}
