import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Configura a sessão de áudio do sistema. Chamar uma vez, no arranque.
///
/// Sem isto, no iOS, a reprodução depois de uma gravação sai pelo alto-falante
/// do ouvido em vez do de viva-voz: o `record` deixa a sessão em
/// `playAndRecord` e o `just_audio` não define categoria nenhuma. O sintoma é
/// enganoso — parece que não tocou, quando na verdade tocou baixinho no lugar
/// errado.
///
/// `speech()` é o preset certo para rádio: voz, viva-voz por padrão, e cede a
/// sessão para chamadas telefônicas.
Future<void> configureAudioSession() async {
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.speech());
}

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
