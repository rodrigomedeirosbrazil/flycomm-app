import 'dart:async';

import '../audio/cues.dart';
import '../audio/playback_queue.dart';
import '../audio/player.dart';
import '../audio/recorder.dart';
import '../history/audio_store.dart';
import '../history/database.dart';
import '../history/history_repository.dart';
import '../trace.dart';
import 'budgets.dart';
import 'catchup_repository.dart';
import 'message_api.dart';
import 'message_uploader.dart';
import 'models.dart';
import 'reverb_client.dart';
import 'server_clock.dart';

/// Uma sessão de sala aberta: o WebSocket, a fila, o gravador e o histórico
/// amarrados. Uma instância por sala aberta; `dispose` ao sair.
class RoomSession {
  RoomSession({
    required this.room,
    required this.budgets,
    required this.clock,
    required this.reverb,
    required this.catchup,
    required this.messageApi,
    required this.history,
    required this.audioStore,
    required this.uploader,
    required this.recorder,
    required this.player,
    this.cues = const SilentCues(),
  }) {
    _queue = PlaybackQueue(
      clock: clock,
      budgets: budgets,
      play: _playFromStore,
    );

    // Item que passou do prazo sai da fila sem tocar e vira "atrasada" no
    // histórico — ouvível por toque, nunca automaticamente.
    _subscriptions.add(_queue.dropped.listen((item) async {
      await history.markLate(item.messageId);
    }));

    _subscriptions.add(reverb.messages.listen(ingest));

    _subscriptions.add(reverb.roomUpdates.listen((updated) {
      _room = updated;
      _roomChanges.add(updated);
    }));

    _subscriptions.add(recorder.segments.listen(_publishSegment));

    _room = room;
  }

  final Room room;
  final Budgets budgets;
  final ServerClock clock;
  final ReverbClient reverb;
  final CatchupRepository catchup;
  final MessageApi messageApi;
  final HistoryRepository history;
  final AudioStore audioStore;

  /// Vem de fora e não é descartado aqui: a insistência dura minutos e precisa
  /// sobreviver ao piloto sair da tela da sala. Ver [MessageUploader].
  final MessageUploader uploader;

  final PttRecorder recorder;
  final SegmentPlayer player;

  /// Os avisos de "pode falar" e "acabou". Silenciosos por padrão porque nos
  /// testes não há aparelho de som.
  final PttCues cues;

  late final PlaybackQueue _queue;

  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _roomChanges = StreamController<Room>.broadcast();
  final _gaps = StreamController<DateTime>.broadcast();
  final _playbackProblems = StreamController<String?>.broadcast();
  final _nowPlaying = StreamController<String?>.broadcast();

  String? _nowPlayingId;

  late Room _room;

  Room get current => _room;
  Stream<Room> get roomChanges => _roomChanges.stream;

  /// Emite quando o catch-up descobriu um buraco no histórico.
  Stream<DateTime> get gaps => _gaps.stream;

  /// Emite a razão quando uma fala não pôde ser tocada, e `null` quando volta
  /// a funcionar.
  ///
  /// O `null` não é detalhe: o aviso fica na tela até ser dispensado, porque a
  /// falha que mais importa acontece com o piloto longe do aparelho. Sem um
  /// sinal de recuperação, ele continuaria mostrando um erro já resolvido — e
  /// foi exatamente o que aconteceu em bancada.
  Stream<String?> get playbackProblems => _playbackProblems.stream;

  /// Qual fala está saindo pelo alto-falante agora, ou `null` no silêncio.
  ///
  /// A fila é FIFO estrita e toca uma voz por vez — mas até aqui a tela não
  /// dizia **qual**. Numa sala de rádio isso é a metade que falta: o piloto
  /// ouve alguém falando e não tem como saber quem, nem voltar naquela fala
  /// depois, porque não sabe qual linha do histórico era.
  ///
  /// Vale para os dois caminhos de reprodução, a fila e o toque no histórico:
  /// os dois passam por [_whilePlaying]. Se valesse só para um, a marca
  /// mentiria justamente quando o piloto fosse conferir.
  Stream<String?> get nowPlaying => _nowPlaying.stream;

  /// O valor atual, para quem assina depois de a reprodução já ter começado —
  /// mesma razão de `presenceNow`.
  String? get nowPlayingId => _nowPlayingId;

  Stream<List<LocalMessage>> get messages => history.watchRoom(room.id);
  Stream<RoomPresence> get presence => reverb.presence;
  Stream<ReverbConnection> get connectionState => reverb.connectionState;

  RoomPresence get presenceNow => reverb.presenceNow;
  ReverbConnection get connectionNow => reverb.connectionNow;

  Future<void> open() async {
    // Cada (re)assinatura roda o catch-up de novo. É isto que cobre o caso para
    // o qual a janela de 60 s foi desenhada: o WebSocket cai e volta oito
    // segundos depois, e o que passou nesse intervalo precisa entrar.
    _subscriptions.add(reverb.connectionState.listen((state) {
      if (state == ReverbConnection.connected) syncCatchup();
    }));

    await reverb.connect(room);
    await syncCatchup();
  }

  /// A recuperação em andamento, se houver. Ver [syncCatchup].
  Future<void>? _catchingUp;

  /// Chamado na entrada e a cada reconexão do WebSocket.
  ///
  /// Os dois gatilhos disparam quase juntos — `open()` pede uma, e o
  /// `connected` do WebSocket pede outra assim que o Reverb confirma a
  /// assinatura —, e sem isto eram dois GET /catchup idênticos por conexão e
  /// dois avisos de buraco para o mesmo buraco.
  ///
  /// Quem chega no meio entra de carona na busca que já está no ar, e isso é
  /// correto e não um atalho: a janela que o servidor devolve é calculada na
  /// hora em que ele responde, que é depois de a segunda chamada ter sido
  /// feita. O que ela queria saber está na resposta que já vem vindo.
  ///
  /// A carona vale só para as simultâneas: terminada a busca, a próxima
  /// chamada vai à rede de novo.
  Future<void> syncCatchup() {
    return _catchingUp ??=
        _syncCatchup().whenComplete(() => _catchingUp = null);
  }

  Future<void> _syncCatchup() async {
    final since = await history.lastSeenAt(room.id);
    final result = await catchup.fetch(room.id, since: since);

    if (result.hasGapSince(since)) _gaps.add(result.windowStart);

    for (final message in result.messages) {
      await ingest(message);
    }
  }

  /// O caminho único de entrada: o evento, a resposta do upload e o catch-up
  /// chegam aqui, porque são a mesma mensagem.
  /// Envolve [_ingest] para que nada falhe em silêncio.
  ///
  /// Este método é assinado direto no stream de eventos e chamado em laço pelo
  /// catch-up. Uma exceção escapando daqui vira erro assíncrono não tratado: a
  /// mensagem some, e nem o piloto nem o log ficam sabendo.
  Future<void> ingest(RoomMessage message) async {
    try {
      await _ingest(message);
    } catch (error) {
      _playbackProblems.add('Não deu para receber uma fala: $error');
    }
  }

  /// Ids sendo processados agora. O `exists` do banco não basta: o evento
  /// `message.new` e o catch-up entregam a mesma mensagem quase junto, e os
  /// dois passam pela checagem antes de qualquer um gravar.
  ///
  /// Medido no aparelho: a mesma fala entrou duas vezes com 132 ms de
  /// diferença, baixando o áudio duas vezes e enfileirando duas reproduções da
  /// mesma coisa — o oposto de "uma voz por vez".
  final _ingesting = <String>{};

  Future<void> _ingest(RoomMessage message) async {
    // A reserva do id é SÍNCRONA, antes de qualquer `await`. A versão anterior
    // olhava o conjunto aqui e só entrava nele depois do `byId`, e nesse
    // intervalo as duas entregas da mesma fala passavam pela checagem: dois
    // downloads, duas entradas na fila, a mesma voz tocando duas vezes.
    if (!_ingesting.add(message.id)) return;

    try {
      final known = await history.byId(message.id);

      // Já conhecida e com áudio no disco: nada a fazer.
      if (known != null && known.audioPath != null) return;

      if (known == null) {
        await _ingestFresh(message);
      } else {
        // Conhecida mas sem áudio: o download falhou antes — rede caindo, app
        // indo para segundo plano no meio. Sem esta segunda chance a mensagem
        // ficaria sem áudio para sempre, porque o `exists` barrava a
        // reingestão e nada mais tentava. O catch-up reentrega a mesma
        // mensagem a cada reconexão, e é essa reentrega que vira a
        // oportunidade de recuperar o que faltou.
        await _fetchAudio(message);
      }
    } finally {
      _ingesting.remove(message.id);
    }
  }

  /// Baixa e guarda o áudio. Devolve `true` quando o arquivo fica no disco.
  Future<bool> _fetchAudio(RoomMessage message) async {
    final tag = _tag(message.id);
    trace('baixando $tag');
    try {
      final bytes = await messageApi.download(message.audioUrl);
      await audioStore.write(message.id, bytes);
      await history.setAudioPath(message.id, audioStore.pathFor(message.id));
      _playbackProblems.add(null);
      trace('guardado $tag');
      return true;
    } catch (error) {
      trace('FALHOU baixar $tag: $error');
      // O blob expirou, a rede caiu, ou a escrita em disco falhou. A linha fica
      // no histórico sem áudio: o piloto vê que algo foi dito e que não dá para
      // ouvir — e a próxima reentrega tenta de novo.
      //
      // O erro vai junto de propósito. A versão anterior fazia `catch (_)` e
      // jogava a causa fora, e o sintoma que sobrava — "mensagem atrasada sem
      // áudio" — é igual para blob vencido, rede ruim e disco recusando
      // escrita, que são três problemas sem nada em comum.
      await history.markLate(message.id);
      _playbackProblems.add('Não deu para guardar o áudio recebido: $error');
      return false;
    }
  }

  Future<void> _ingestFresh(RoomMessage message) async {

    // A idade é a DA FALA, não a da chegada (spec 2.1): com entrega atrasada
    // permitida, `created_at` mede o tempo errado — uma fala de três minutos
    // atrás recebida agora tem `created_at` de agora e tocaria como se fosse
    // nova. Origem `radio` não tem `captured_at`, e aí a chegada é o que há.
    final spokenAt = message.capturedAt ?? message.createdAt;

    // O excedente da janela de catch-up não toca, mas preenche o histórico:
    // sem isso haveria um buraco sem nenhum indício de que algo aconteceu ali.
    final tooOld = clock.ageOf(spokenAt) > budgets.playbackDeadline;

    // Só em debug: a decisão "toca ou não toca" depende de três coisas que não
    // aparecem em lugar nenhum quando dão errado — o desvio do relógio, a
    // idade calculada e o orçamento lido do servidor.
    trace(
      'ingest ${_tag(message.id)} '
      'falada=$spokenAt '
      'agora=${clock.now()} '
      'idade=${clock.ageOf(spokenAt).inMilliseconds}ms '
      'prazo=${budgets.playbackDeadline.inMilliseconds}ms '
      'sincronizado=${clock.isSynced} desvio=${clock.skew.inMilliseconds}ms '
      'vencida=$tooOld',
    );

    await history.recordIncoming(
      message,
      tooOld ? MessageState.late : MessageState.received,
    );

    if (!await _fetchAudio(message)) return;

    if (!tooOld) {
      _queue.enqueue(
        QueuedItem(messageId: message.id, spokenAt: spokenAt),
      );
    }
  }

  /// Nunca lança: uma exceção aqui subiria pela PlaybackQueue e mataria a
  /// rodada em silêncio, levando a mensagem junto.
  ///
  /// Falhar sem dizer nada é o modo de falha mais caro que este app tem — foi
  /// assim que uma fala tocada no alto-falante errado passou por "não tocou".
  /// Quando não dá para tocar, a mensagem vira atrasada: continua ouvível por
  /// toque, e o piloto vê que algo aconteceu.
  /// Anuncia quem está tocando enquanto [body] roda, e o silêncio depois.
  ///
  /// O `finally` não é zelo: a reprodução é interrompida de propósito — PTT
  /// acionado, ligação entrando —, e se a marca não saísse nesses caminhos a
  /// tela ficaria dizendo que alguém fala enquanto o rádio está mudo.
  Future<void> _whilePlaying(String messageId, Future<void> Function() body) async {
    _nowPlayingId = messageId;
    if (!_nowPlaying.isClosed) _nowPlaying.add(messageId);
    try {
      await body();
    } finally {
      _nowPlayingId = null;
      if (!_nowPlaying.isClosed) _nowPlaying.add(null);
    }
  }

  Future<void> _playFromStore(QueuedItem item) async {
    final tag = _tag(item.messageId);
    trace('fila: vez de $tag, tem audio=${audioStore.has(item.messageId)}');

    if (!audioStore.has(item.messageId)) {
      await history.markLate(item.messageId);
      _playbackProblems.add('Uma fala chegou sem áudio e não tocou.');
      return;
    }

    try {
      trace('tocando $tag');
      await _whilePlaying(
        item.messageId,
        () => player.play(audioStore.pathFor(item.messageId)),
      );
      trace('terminou $tag');
      await history.markPlayed(item.messageId);
      _playbackProblems.add(null);
    } catch (error) {
      trace('FALHOU tocar $tag: $error');
      await history.markLate(item.messageId);
      _playbackProblems.add('Não deu para tocar uma fala: $error');
    }
  }

  /// Reprodução por toque, do histórico. Entra na mesma fila e respeita o
  /// meio-duplex, mas ignora o prazo: o piloto pediu para ouvir.
  /// Devolve `null` quando tocou, ou a razão de não ter tocado.
  ///
  /// Devolver a razão em vez de engolir o erro é deliberado: uma mensagem que
  /// não toca e não explica nada é indistinguível de um app quebrado, e o
  /// piloto precisa saber se o áudio sumiu ou se o aparelho falhou.
  Future<String?> playFromHistory(String messageId) async {
    // Meio-duplex: enquanto o PTT está acionado, nada toca. A documentação
    // desta função já prometia isto e o código não cumpria — só não aparecia
    // porque exigia dois dedos. Com o botão de repetir encostado no PTT,
    // passa a aparecer.
    if (_queue.pttHeld) {
      return 'O microfone está aberto. Solte o PTT para ouvir.';
    }

    if (!audioStore.has(messageId)) {
      return 'O áudio não está no aparelho: ele venceu no servidor antes de '
          'dar tempo de baixar.';
    }

    try {
      await _whilePlaying(
        messageId,
        () => player.play(audioStore.pathFor(messageId)),
      );
      // Ouvida por toque conta como ouvida: a pergunta que a marca responde é
      // "já escutei isto?", não "a fila tocou isto?".
      await history.markHeard(messageId);
      return null;
    } catch (error) {
      return 'Não deu para tocar: $error';
    }
  }


  /// Para o que estiver tocando, sem mexer na fila. Usado quando o sistema
  /// tira a sessão de áudio do app — ligação entrando, fone desconectado.
  Future<void> stopPlayback() => player.interrupt();

  /// Meio-duplex: enquanto o PTT está acionado, nada toca.
  ///
  /// A ordem dos quatro passos é toda deliberada. Segurar a fila **antes** de
  /// interromper impede que a fala seguinte comece no vão; o aviso toca com a
  /// fila já segura, então ele nunca disputa com uma voz; e ele toca **até o
  /// fim** antes de a captura abrir, senão o microfone gravaria o próprio
  /// aviso quando não houver fone.
  Future<void> pressPtt() async {
    _queue.pttHeld = true;
    await player.interrupt();
    await cues.ready();

    try {
      await recorder.start();
    } catch (error) {
      // O aviso de "pode falar" já tocou quando chegamos aqui, e ele acabou de
      // virar mentira. Com a tela bloqueada o som é o único canal que resta,
      // então desmentir é obrigação, não cortesia.
      //
      // Acontece de verdade e por regra do sistema: o iOS proíbe **iniciar**
      // gravação com o app em segundo plano — `CMSession: Client is in the
      // background and doesn't have the entitlement to start recording in the
      // background`. Não há chave de Info.plist que libere. O Android não tem
      // essa regra.
      await cues.failed();
      _queue.pttHeld = false;
      rethrow;
    }
  }

  /// Simétrico: o aviso de fim toca com a fila ainda segura, e só depois a
  /// conversa volta. Soltar a fila antes deixaria o "acabou" por cima da
  /// próxima fala.
  Future<void> releasePtt() async {
    await recorder.stop();
    await cues.done();
    _queue.pttHeld = false;
  }

  Future<void> _publishSegment(CapturedSegment segment) async {
    final path = await audioStore.write(segment.id, segment.wavBytes);

    await history.recordOutgoing(
      id: segment.id,
      roomId: room.id,
      burstId: segment.burstId,
      index: segment.index,
      durationMs: segment.durationMs,
      format: MessageApi.format,
      capturedAt: segment.capturedAt,
      audioPath: path,
    );

    await uploader.upload(OutgoingSegment(
      id: segment.id,
      roomId: room.id,
      burstId: segment.burstId,
      index: segment.index,
      durationMs: segment.durationMs,
      capturedAt: segment.capturedAt,
      wavBytes: segment.wavBytes,
    ));
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _queue.dispose();
    await reverb.dispose();
    await recorder.dispose();
    await player.dispose();
    await _roomChanges.close();
    await _gaps.close();
    await _playbackProblems.close();
    await _nowPlaying.close();
  }
}

/// As oito primeiras letras do id, para o rastro de depuração.
///
/// Existe porque `substring(0, 8)` **lança** num id mais curto que oito, e o
/// estrago disso é desproporcional ao de um log feio: a exceção sobe até
/// [RoomSession.ingest], que a converte em "Não deu para receber uma fala". Um
/// erro de formatar log se disfarça de falha de rede, e a fala some do
/// histórico junto.
///
/// Não morde em produção porque todo id de mensagem é um uuid gerado pelo app.
/// É exatamente por isso que precisa de guarda: o caminho curto só é
/// exercitado por acidente, e quando for, o sintoma vai apontar para o lugar
/// errado.
String _tag(String id) => id.length <= 8 ? id : id.substring(0, 8);
