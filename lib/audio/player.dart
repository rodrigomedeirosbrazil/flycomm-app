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
  ///
  /// Não chame `stop()` aqui. No just_audio, `stop()` **libera os recursos
  /// nativos** do decodificador, não é um "parar" simples: o player seguinte
  /// encontra um ExoPlayer já liberado e a reprodução falha.
  ///
  /// Medido no aparelho: a primeira fala tocava (16000 quadros entregues a
  /// 16 kHz, o segmento inteiro), vinha `ExoPlayerImpl: Release`, e da segunda
  /// em diante tudo chegava como "atrasada" — porque a falha de reprodução é
  /// marcada assim. O sintoma parecia de frescor e era de ciclo de vida do
  /// player.
  ///
  /// O próximo `setFilePath` já troca a fonte; não há o que limpar entre falas.
  Future<void> play(String filePath) async {
    // `pause()` antes de trocar a fonte, e isto NÃO é higiene — é o que faz
    // este método cumprir a promessa acima.
    //
    // O `play()` do just_audio devolve **na hora** quando o player já está com
    // `playing == true`, e ele continua assim depois que a faixa termina: o
    // pacote não desliga a flag no fim. Então só a primeira fala de cada
    // sessão era esperada de verdade; da segunda em diante o `await` voltava
    // em dezenas de milissegundos, a PlaybackQueue achava que a reprodução
    // tinha acabado e mandava a próxima — cujo `setFilePath` cortava a que
    // estava de fato tocando.
    //
    // Medido no aparelho, numa rajada de três segmentos: a primeira fala
    // tocou 5,234 s e as duas seguintes "tocaram" em 52 ms e 73 ms. O sintoma
    // era intermitente porque uma fala avulsa soa normal mesmo com o `await`
    // quebrado — não há ninguém na fila para cortá-la. Só a rajada revela.
    //
    // `pause()` e não `stop()`: stop libera o decodificador nativo e a fala
    // seguinte não toca (ver [interrupt]).
    await _player.pause();
    await _player.setFilePath(filePath);
    await _player.play();
  }

  /// Interrompe o que estiver tocando — PTT acionado, ligação entrando.
  ///
  /// `pause()` e não `stop()`, pela mesma razão: interromper não deveria custar
  /// o player. O item interrompido é descartado de qualquer forma, então a
  /// posição não importa.
  Future<void> interrupt() => _player.pause();

  Future<void> dispose() => _player.dispose();
}
