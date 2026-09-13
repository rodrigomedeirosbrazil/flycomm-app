import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'wav.dart';

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
/// A fatia é escuta em segundo plano no iOS.
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
    await session.configure(const AudioSessionConfiguration.speech());
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

  /// ANDAIME DE BANCADA — ler antes de mexer.
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
  /// Tocar silêncio em laço resolve, e é a técnica conhecida — mas é andaime,
  /// não solução: gasta bateria continuamente e a Apple desencoraja, sendo
  /// motivo conhecido de recusa na App Store. Existe para responder a pergunta
  /// que a Fase 3 precisa: o WebSocket aguenta uma hora no bolso se o processo
  /// ficar vivo?
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
      await player.setVolume(0);
    }

    await player.play();
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
