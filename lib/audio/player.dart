import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'flight_session.dart';

/// Configura a sessão de áudio no arranque, para que a reprodução funcione
/// antes de o piloto entrar em voo.
///
/// A configuração em si mora em [radioSessionConfiguration], fonte única: ter
/// duas configurações diferentes em dois lugares foi como a reprodução acabou
/// saindo pelo alto-falante do ouvido.
Future<void> configureAudioSession() async {
  final session = await AudioSession.instance;
  await session.configure(radioSessionConfiguration);
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
