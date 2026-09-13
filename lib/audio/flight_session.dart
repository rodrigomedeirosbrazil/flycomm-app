import 'dart:async';

import 'package:audio_session/audio_session.dart';

/// "Entrar em voo": a ação explícita que mantém o app ouvindo com a tela
/// apagada.
///
/// No iOS, o que segura o processo vivo é a `AVAudioSession` **ativa**, não o
/// `UIBackgroundModes` sozinho — o modo declara a intenção, a sessão ativa é o
/// que a cumpre. Enquanto ela vive, o processo vive, e o WebSocket junto. É por
/// isso que "tocar em segundo plano" não é um problema de áudio: sem a sessão,
/// a conexão morre e não chega `message.new` nenhum para tocar.
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

    _inFlight = true;
    _changes.add(true);
  }

  /// Sai de voo e devolve a sessão ao sistema. A partir daqui o app volta a ser
  /// suspenso normalmente com a tela apagada — e é isso que se quer, porque
  /// manter a sessão ativa fora de voo consome bateria por nada.
  Future<void> leave() async {
    if (!_inFlight) return;

    await _onInterrupted();
    await _session?.setActive(false);

    _inFlight = false;
    _changes.add(false);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _session?.setActive(false);
    await _changes.close();
  }
}
