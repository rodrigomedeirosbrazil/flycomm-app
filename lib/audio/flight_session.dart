import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'wav.dart';

/// A sessão de áudio de um rádio.
///
/// `playAndRecord` porque o app faz as duas coisas, e trocar de categoria a
/// cada PTT deixa a sessão num estado que ninguém devolve: o `record` muda para
/// `playAndRecord` ao gravar e não volta, e a reprodução seguinte sai pelo
/// alto-falante do ouvido. Foi assim que uma fala recebida com o celular no
/// bolso ficou inaudível — não deixou de tocar, tocou no lugar errado.
///
/// `defaultToSpeaker` é o que corrige a rota quando não há fone;
/// `spokenAudio` diz ao sistema que isto é voz e não música, o que muda como
/// outros apps são abaixados.
///
/// **`allowBluetoothA2dp` sim, `allowBluetooth` não — e a escolha é dolorosa.**
/// No iPhone dá para ter o microfone do fone ou os botões dele, nunca os dois:
/// com `allowBluetooth` (HFP) a captura vem do fone e o
/// `MPRemoteCommandCenter` **para de receber**, então nenhum gesto chega
/// (reproduzido e sem resposta da Apple no fórum 688838). Com A2DP só, o gesto
/// chega, o som sai no fone, e a captura volta para o microfone do iPhone.
///
/// Enquanto o gesto for a forma de acionar o PTT, é A2DP. Trocar de perfil
/// durante a gravação é possível e é a saída a prazo, mas cobra o seu preço:
/// sob HFP o botão morre, então o gesto não consegue **encerrar** a fala.
///
/// Isto só vale se ninguém mais mexer na sessão. Ver `PttRecorder`, que
/// chamava `setCategory` por conta própria a cada PTT — com
/// `[defaultToSpeaker, allowBluetooth, allowBluetoothA2DP]`, o padrão do
/// `IosRecordConfig` — e deixava assim para sempre.
///
/// É o que a seção 5.5 da spec do sistema já pedia: "uma AVAudioSession em
/// playAndRecord mantida ativa".
final radioSessionConfiguration = AudioSessionConfiguration(
  avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
  avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker |
      AVAudioSessionCategoryOptions.allowBluetoothA2dp,
  avAudioSessionMode: AVAudioSessionMode.spokenAudio,
  androidAudioAttributes: const AndroidAudioAttributes(
    contentType: AndroidAudioContentType.speech,
    usage: AndroidAudioUsage.media,
  ),
  androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
  androidWillPauseWhenDucked: true,
);

/// "Entrar em voo": a ação explícita que mantém o app ouvindo com a tela
/// apagada.
///
/// No iOS são precisas três coisas, e faltar qualquer uma derruba tudo:
/// `UIBackgroundModes: audio` declarado, a `AVAudioSession` **ativa**, e áudio
/// **de fato saindo** — ver [_startKeepAlive]. Sessão ativa mas silenciosa não
/// segura nada, e foi assim que a primeira versão disto falhou em bancada.
///
/// Enquanto o processo vive, o WebSocket vive junto. É por isso que "tocar em
/// segundo plano" nunca foi um problema de áudio: sem processo, a conexão
/// morre, não chega `message.new` e não há o que tocar. O áudio é a última
/// peça, não a primeira.
///
/// A ação é explícita e feita com o app aberto de propósito (7.1 da spec). No
/// Android ela será obrigatória — desde o Android 12 um serviço com tipo
/// `microphone` só inicia com o app visível —, e aqui ela é o momento de dizer
/// ao piloto que o app assumiu o rádio.
///
/// O que esta classe NÃO faz: gravar em segundo plano, e nada do lado Android.
/// A fatia é escuta em segundo plano no iOS. **No Android entrar em voo não
/// entrega escuta em segundo plano** — isso exige Foreground Service, que é
/// Fase 4. A barra aparece nas duas plataformas e só cumpre o que promete numa;
/// decidir se esconde ou se rotula diferente está em aberto.
class FlightSession {
  FlightSession({required Future<void> Function() onInterrupted})
      : _onInterrupted = onInterrupted;

  /// Chamado quando o sistema tira a sessão do app — ligação entrando, outro
  /// app assumindo o áudio, fone desconectado. Quem escuta para a reprodução;
  /// retomar é decisão de quem toca, não desta classe.
  final Future<void> Function() _onInterrupted;

  final _changes = StreamController<bool>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];

  AudioSession? _session;
  AudioPlayer? _keepAlive;
  bool _inFlight = false;

  bool get isInFlight => _inFlight;
  Stream<bool> get changes => _changes.stream;

  Future<AudioSession> _ensure() async {
    final existing = _session;
    if (existing != null) return existing;

    final session = await AudioSession.instance;
    await session.configure(radioSessionConfiguration);
    _session = session;

    // Ligação entrando, ou outro app assumindo o áudio.
    _subscriptions.add(session.interruptionEventStream.listen((event) {
      if (event.begin) _onInterrupted();
    }));

    // Fone desconectado: o áudio passaria a sair no alto-falante, alto, no
    // bolso de alguém. Parar é o comportamento menos surpreendente.
    _subscriptions.add(
      session.becomingNoisyEventStream.listen((_) => _onInterrupted()),
    );

    return session;
  }

  /// Entra em voo. Idempotente: chamar duas vezes não faz mal.
  Future<void> enter() async {
    if (_inFlight) return;

    final session = await _ensure();
    await session.setActive(true);
    await _startKeepAlive();

    _inFlight = true;
    _changes.add(true);
  }

  /// ANDAIME QUE SUSTENTA PESO — ler antes de mexer, e não remover.
  ///
  /// `UIBackgroundModes: audio` mantém o app vivo **enquanto ele está de fato
  /// produzindo áudio**. Uma sessão ativa mas silenciosa não segura nada: o iOS
  /// suspende depois de alguns segundos. E o nosso caso é o silencioso — o app
  /// espera alguém falar, que é o oposto de estar tocando.
  ///
  /// Medido em bancada: com a sessão ativa mas sem áudio saindo, o aparelho
  /// saiu da presença ao bloquear a tela, e a fala só chegou pelo catch-up ao
  /// desbloquear, já vencida.
  ///
  /// Tocar silêncio em laço resolve, e é a técnica conhecida. **Medido no
  /// aparelho, com a tela bloqueada:** três de quatro falas chegaram ao vivo em
  /// 162–382 ms, a última depois de 44 s de conexão ociosa, e o som saiu. Sem
  /// isto, a quarta seria a regra: reconexão e catch-up, 5,8 s, já vencida.
  ///
  /// Houve uma versão desta nota recomendando remover isto por "gastar bateria
  /// sem entregar garantia". Estava errada, e pela razão de sempre: o que
  /// derrubava a entrega era o `APP_URL` do servidor apontando para
  /// `localhost`, não o iOS. Ver `docs/fase-2-aceitacao.md`, §7.1 revisada.
  ///
  /// Continua sendo andaime: gasta bateria continuamente e a Apple desencoraja,
  /// sendo motivo conhecido de recusa na App Store. Sai quando o PushToTalk
  /// entrar — não antes.
  ///
  /// O caminho sancionado é o framework PushToTalk (iOS 16+), que a spec do
  /// sistema já registrou como Fase 5: exige entitlement, conta paga e APNs.
  /// Quando ele entrar, isto sai inteiro.
  Future<void> _startKeepAlive() async {
    final player = _keepAlive ??= AudioPlayer();

    if (player.audioSource == null) {
      final file = File('${(await getTemporaryDirectory()).path}/keepalive.wav');
      if (!file.existsSync()) {
        // Dez segundos de zeros: silêncio de verdade. Curto demais acordaria a
        // CPU a cada laço; longo demais só ocupa disco à toa.
        await file.writeAsBytes(
          wrapPcmInWav(Uint8List(10000 * bytesPerMs)),
          flush: true,
        );
      }
      await player.setFilePath(file.path);
      await player.setLoopMode(LoopMode.one);
      // Volume cheio de propósito: o arquivo é só zeros, então já é inaudível,
      // e volume zero é ambíguo — não está claro se o iOS conta um player
      // mudo como "produzindo áudio" para efeito de segundo plano. Silêncio
      // por conteúdo não deixa margem; silêncio por volume deixa.
      await player.setVolume(1);
    }

    await player.play();

    // Sem isto, um keep-alive que não pegou vira suspensão silenciosa minutos
    // depois, longe da causa: o piloto guarda o celular achando que está
    // ouvindo e volta sem nada.
    if (!player.playing) {
      throw StateError(
        'o silêncio de manutenção não começou a tocar; sem ele o iOS suspende '
        'o app com a tela apagada',
      );
    }
  }

  /// Sai de voo e devolve a sessão ao sistema. A partir daqui o app volta a ser
  /// suspenso normalmente com a tela apagada — e é isso que se quer, porque
  /// manter a sessão ativa fora de voo consome bateria por nada.
  Future<void> leave() async {
    if (!_inFlight) return;

    await _onInterrupted();
    await _keepAlive?.stop();
    await _session?.setActive(false);

    _inFlight = false;
    _changes.add(false);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _keepAlive?.dispose();
    _keepAlive = null;
    await _session?.setActive(false);
    await _changes.close();
  }
}
