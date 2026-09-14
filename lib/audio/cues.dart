import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'wav.dart';

/// Os dois avisos de PTT: "pode falar" e "acabou".
///
/// Existem porque o gesto no fone é cego. Com o botão da tela o piloto vê o
/// microfone aberto; com o celular no bolso ele não vê nada, e falar achando
/// que gravou é o pior desfecho possível — a fala se perde e ninguém avisa.
abstract class PttCues {
  /// Toca **até o fim** antes de a gravação começar. É gate, não enfeite: sem
  /// fone conectado o som sai no alto-falante, e sobrepor o aviso à captura
  /// gravaria o próprio aviso.
  Future<void> ready();

  /// Depois de a gravação fechar.
  Future<void> done();
}

/// O que os testes usam: não há aparelho de som num `flutter test`.
class SilentCues implements PttCues {
  const SilentCues();

  @override
  Future<void> ready() async {}

  @override
  Future<void> done() async {}
}

/// Dois tons sintetizados, sem arquivo de asset.
///
/// Sintetizados e não gravados porque o app já sabe montar PCM e embrulhar em
/// WAV — dois assets seriam duas coisas a versionar, empacotar e manter
/// afinadas com a taxa de amostragem que o resto da camada de áudio usa.
class ToneCues implements PttCues {
  /// Subindo para abrir, descendo para fechar. A diferença de altura é o que
  /// permite distinguir os dois sem olhar, que é o ponto inteiro.
  static const _readyHz = 1100.0;
  static const _doneHz = 660.0;

  final _readyPlayer = AudioPlayer();
  final _donePlayer = AudioPlayer();

  Future<void>? _preparing;

  Duration _latency = Duration.zero;

  /// A última latência de saída medida — quanto tempo o som leva do player até
  /// o ouvido. No alto-falante é quase nada; num fone A2DP são tipicamente
  /// mais de 100 ms. Aparece no painel de diagnóstico porque é número medido,
  /// não constante escolhida.
  Duration get latency => _latency;

  /// Vale chamar ao abrir a sala. O primeiro `setFilePath` custa dezenas de
  /// milissegundos, e pagá-los no primeiro PTT atrasaria justamente o aviso de
  /// que se pode falar.
  Future<void> prepare() => _preparing ??= _prepare();

  Future<void> _prepare() async {
    final directory = await getTemporaryDirectory();

    await _load(_readyPlayer, '${directory.path}/cue-ready.wav', _readyHz,
        const Duration(milliseconds: 90));
    await _load(_donePlayer, '${directory.path}/cue-done.wav', _doneHz,
        const Duration(milliseconds: 150));
  }

  Future<void> _load(
    AudioPlayer player,
    String path,
    double hz,
    Duration length,
  ) async {
    await File(path).writeAsBytes(
      wrapPcmInWav(_tone(hz: hz, length: length)),
      flush: true,
    );
    await player.setFilePath(path);
  }

  @override
  Future<void> ready() => _play(_readyPlayer);

  @override
  Future<void> done() => _play(_donePlayer);

  /// ANDAIME QUE SUSTENTA PESO — as três linhas estão na ordem que estão por
  /// motivos diferentes, e tirar qualquer uma quebra de um jeito silencioso.
  ///
  /// `seek` e não `stop`: `stop()` libera o decodificador nativo no just_audio,
  /// e o aviso seguinte encontraria um ExoPlayer morto. Mesmo defeito que já
  /// custou caro no SegmentPlayer.
  ///
  /// `pause` **depois** de tocar não é higiene, é o conserto de um bug medido:
  /// `play()` começa com `if (playing) return`, e o just_audio não devolve
  /// `playing` para falso quando a fonte acaba — ela fica em `completed` com
  /// `playing` verdadeiro. Sem este `pause`, o primeiro aviso esperava e **do
  /// segundo em diante o `await` voltava na hora**, abrindo o microfone por
  /// cima do som.
  ///
  /// E o `play()` completa quando o *player* termina de renderizar, não quando
  /// o som chega ao ouvido: num fone Bluetooth ainda há mais de 100 ms de
  /// caminho. Esperar a latência de saída é o que faz o aviso ser um portão de
  /// verdade em vez de um portão no papel.
  Future<void> _play(AudioPlayer player) async {
    await prepare();

    await player.seek(Duration.zero);
    await player.play();
    await player.pause();

    await _measureLatency();
    if (_latency > Duration.zero) await Future<void>.delayed(_latency);
  }

  /// Medida a cada aviso porque a rota muda embaixo do app: o piloto conecta o
  /// fone no meio do voo, ou ele cai sozinho.
  ///
  /// **Medido no iPhone de Rodrigo, iOS 26.6.2, fone Bluetooth: 150 ms.**
  /// Coerente com A2DP, e prova que o número serve — havia motivo para duvidar,
  /// porque o iOS tem fama de subnotificar latência de Bluetooth.
  ///
  /// O teto de 400 ms é desconfiança deliberada: o `outputLatency` está
  /// marcado como não testado no `audio_session`, e um valor absurdo viraria
  /// um PTT que parece travado. Errar para menos aqui só devolve o problema
  /// pequeno de origem.
  Future<void> _measureLatency() async {
    if (!Platform.isIOS) return;

    try {
      final measured = await AVAudioSession().outputLatency;
      _latency = measured > const Duration(milliseconds: 400)
          ? const Duration(milliseconds: 400)
          : measured;
    } catch (_) {
      // Uma medida que não veio não pode derrubar o PTT.
      _latency = Duration.zero;
    }
  }

  Future<void> dispose() async {
    await _readyPlayer.dispose();
    await _donePlayer.dispose();
  }
}

/// Uma senoide com bordas suavizadas.
///
/// A suavização não é capricho: um tom que começa e termina no meio do ciclo
/// produz um estalo, e um estalo num aviso que toca a cada PTT vira a coisa
/// mais irritante do app.
Uint8List _tone({required double hz, required Duration length}) {
  final samples = length.inMilliseconds * sampleRate ~/ 1000;

  // Cerca de 27% da escala. Alto o bastante para se ouvir com vento, baixo o
  // bastante para não machucar quem está de fone.
  const amplitude = 9000;
  final fade = sampleRate ~/ 200; // 5 ms de subida e de descida

  final pcm = Uint8List(samples * 2);
  final view = ByteData.sublistView(pcm);

  for (var i = 0; i < samples; i++) {
    final edge = min(i, samples - 1 - i) / fade;
    final envelope = min(1.0, edge);
    final value = amplitude * envelope * sin(2 * pi * hz * i / sampleRate);

    view.setInt16(i * 2, value.round(), Endian.little);
  }

  return pcm;
}
