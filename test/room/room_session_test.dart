import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/player.dart';
import 'package:flycomm/audio/recorder.dart';
import 'package:flycomm/history/audio_store.dart';
import 'package:flycomm/history/database.dart';
import 'package:flycomm/history/history_repository.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/budgets.dart';
import 'package:flycomm/room/catchup_repository.dart';
import 'package:flycomm/room/message_api.dart';
import 'package:flycomm/room/message_uploader.dart';
import 'package:flycomm/room/models.dart';
import 'package:flycomm/room/reverb_client.dart';
import 'package:flycomm/room/room_session.dart';
import 'package:flycomm/room/server_clock.dart';
import 'package:record/record.dart';

/// O gravador não participa deste teste, e construir o de verdade chama o
/// plugin nativo, que não existe aqui.
class _SilentRecorder implements AudioRecorder {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Não toca nada. A invariante em teste é de ordem, não de som, e um teste de
/// host nunca deveria construir um player de verdade.
class _SilentPlayer extends SegmentPlayer {
  /// O que foi pedido, na ordem. Uma rajada de três segmentos tocada inteira e
  /// uma tocada pela metade só se distinguem por isto.
  final played = <String>[];

  /// Roda **dentro** de cada reprodução, que é onde o meio-duplex da repetição
  /// precisa ser observado: entre um segmento e o próximo.
  void Function()? onPlay;

  /// Quando ligado, cada reprodução fica pendurada até [release]. É o que
  /// permite observar duas falas em voo ao mesmo tempo — que é exatamente o
  /// que o player de verdade faz quando uma começa por cima da outra.
  bool holdAll = false;
  final _holds = <String, Completer<void>>{};

  void release(String idFragment) {
    final key = _holds.keys.firstWhere((k) => k.contains(idFragment));
    _holds.remove(key)!.complete();
  }

  void releaseAll() {
    for (final hold in _holds.values.toList()) {
      hold.complete();
    }
    _holds.clear();
  }

  @override
  Future<void> play(String filePath) async {
    played.add(filePath);
    onPlay?.call();
    if (!holdAll) return;
    final hold = Completer<void>();
    _holds[filePath] = hold;
    await hold.future;
  }

  @override
  Future<void> interrupt() async {}
}

/// Abre e fecha o PTT sem tocar no microfone.
class _OpenablePttRecorder extends PttRecorder {
  _OpenablePttRecorder({required super.segmentMax, required super.serverNow})
      : super(recorder: _SilentRecorder());

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// Conta o que o app pede à rede: downloads de áudio e rodadas de catch-up.
class _CountingAdapter implements HttpClientAdapter {
  int downloads = 0;
  int catchups = 0;

  /// Quanto cada resposta demora. É neste respiro que a segunda chamada
  /// alcança a primeira.
  Duration latency = const Duration(milliseconds: 20);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final isCatchup = options.uri.path.endsWith('/catchup');
    if (isCatchup) {
      catchups++;
    } else {
      downloads++;
    }

    await Future<void>.delayed(latency);

    if (isCatchup) {
      final now = DateTime.now().toUtc().toIso8601String();
      return ResponseBody.fromString(
        jsonEncode({
          'server_time': now,
          'window_start': now,
          'messages': <dynamic>[],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    return ResponseBody.fromBytes(List<int>.filled(64, 0), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const budgets = Budgets(
    playbackDeadline: Duration(seconds: 30),
    radioRelayDeadline: Duration(seconds: 10),
    deliveryDeadline: Duration(minutes: 5),
    segmentMax: Duration(seconds: 5),
    catchupWindow: Duration(seconds: 60),
    blobTtl: Duration(minutes: 5),
  );

  const room = Room(
    id: 255,
    name: 'Sala',
    frequencyHz: null,
    inviteCode: 'FLY-TEST',
    createdBy: 1,
    members: [],
  );

  late HistoryDatabase db;
  late _CountingAdapter adapter;
  late Directory temp;
  late RoomSession session;
  late _SilentPlayer player;

  setUp(() async {
    db = HistoryDatabase(NativeDatabase.memory());
    adapter = _CountingAdapter();
    temp = await Directory.systemTemp.createTemp('flycomm-test');
    player = _SilentPlayer();

    final api = ApiClient(baseUrl: 'http://servidor');
    api.raw.httpClientAdapter = adapter;

    final clock = ServerClock();
    final history = HistoryRepository(db);
    final messageApi = MessageApi(api: api);

    session = RoomSession(
      room: room,
      budgets: budgets,
      clock: clock,
      reverb: ReverbClient(api: api, appKey: 'k', host: 'localhost', port: 8080),
      catchup: CatchupRepository(api: api, clock: clock),
      messageApi: messageApi,
      history: history,
      audioStore: AudioStore(temp),
      uploader: MessageUploader(
        clock: clock,
        budgets: budgets,
        history: history,
        publish: messageApi.publish,
      ),
      recorder: _OpenablePttRecorder(
        segmentMax: budgets.segmentMax,
        serverNow: clock.now,
      ),
      player: player,
    );
  });

  tearDown(() async {
    await db.close();
    temp.deleteSync(recursive: true);
  });

  RoomMessage message(String id) => RoomMessage(
        id: id,
        roomId: room.id,
        burstId: 'b-1',
        index: 0,
        authorId: 510,
        authorName: 'Marina',
        durationMs: 5000,
        origin: 'app',
        format: 'wav-pcm16-16k',
        sizeBytes: 160044,
        capturedAt: DateTime.now().toUtc(),
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        audioUrl: 'http://servidor/messages/$id/audio',
      );

  test('duas recuperações pedidas ao mesmo tempo viram uma busca só', () async {
    // O que acontece a cada (re)conexão: `open()` pede uma, e o evento
    // `connected` do WebSocket pede outra um instante depois.
    await Future.wait([session.syncCatchup(), session.syncCatchup()]);

    expect(adapter.catchups, 1,
        reason: 'duas recuperações concorrentes são dois GET /catchup e dois '
            'avisos de buraco para o mesmo buraco');
  });

  test('a recuperação seguinte busca de novo: a junção é só das simultâneas',
      () async {
    await session.syncCatchup();
    await session.syncCatchup();

    expect(adapter.catchups, 2);
  });

  test('a mesma fala entregue duas vezes ao mesmo tempo baixa e toca uma vez',
      () async {
    final m = message('11111111-1111-1111-1111-111111111111');

    // O evento `message.new` e o catch-up — ou dois WebSockets vivos — entregam
    // a mesma mensagem sem que uma espere a outra.
    await Future.wait([session.ingest(m), session.ingest(m)]);

    expect(adapter.downloads, 1,
        reason: 'duas ingestões simultâneas viram dois downloads e duas '
            'reproduções da mesma fala');
  });

  test('com o PTT acionado, tocar do histórico não abre uma segunda voz',
      () async {
    // A invariante é da spec, não conveniência do app: uma voz por vez, e
    // enquanto o PTT está acionado nada toca. O botão de repetir encosta no
    // PTT, então isto deixa de ser um acidente raro.
    await session.ingest(message('m-1'));
    await session.pressPtt();

    final problem = await session.playFromHistory('m-1');

    expect(problem, isNotNull);
    expect(problem, contains('PTT'));
  });

  test('id curto não vira falha de recepção disfarçada', () async {
    // O rastro de depuração corta o id em oito letras, e `substring` lança
    // quando o id é mais curto que isso. A exceção sobe até `ingest`, que
    // existe justamente para nada falhar em silêncio, e vira "Não deu para
    // receber uma fala" — um erro de formatar log disfarçado de falha de rede,
    // com a fala sumindo do histórico junto.
    //
    // Não morde em produção porque todo id real é um uuid, e é exatamente por
    // isso que precisa de teste: o caminho só é exercitado por acidente.
    final problems = <String?>[];
    final watching = session.playbackProblems.listen(problems.add);

    await session.ingest(message('curto'));
    await pumpEventQueue();
    await watching.cancel();

    // `null` neste stream é o sinal de recuperação — "voltou a funcionar" —,
    // não um problema. O que não pode aparecer é razão nenhuma.
    expect(problems.whereType<String>(), isEmpty);
    expect(await session.history.byId('curto'), isNotNull);
  });




  test('anuncia quem está tocando, e o silêncio depois', () async {
    final announced = <String?>[];
    final watching = session.nowPlaying.listen(announced.add);

    await session.ingest(message('m-1'));
    await pumpEventQueue();
    await watching.cancel();

    expect(announced, ['m-1', null]);
  });

  test('a marca de quem está tocando sai mesmo quando a reprodução falha',
      () async {
    // O `finally` do anúncio não é zelo: a reprodução é interrompida de
    // propósito — PTT acionado, ligação entrando, fone desconectado. Se a
    // marca não saísse nesses caminhos, a tela ficaria dizendo que alguém fala
    // com o rádio mudo, que é pior que não dizer nada.
    player.onPlay = () => throw StateError('sessão de áudio tomada');

    final announced = <String?>[];
    final watching = session.nowPlaying.listen(announced.add);

    await session.ingest(message('m-1'));
    await pumpEventQueue();
    await watching.cancel();

    expect(announced.last, isNull, reason: 'o silêncio precisa ser anunciado');
  });


  test('tocar outra fala move a marca, e o fim da anterior não a apaga',
      () async {
    // O player é um só: mandar B tocar encerra a reprodução de A, então o
    // `finally` de A roda DEPOIS do anúncio de B. Sem a guarda, o último a
    // falar é o de A e a tela apaga o destaque no instante em que B começou —
    // o piloto toca outra fala e nada muda na tela.
    await session.ingest(message('fala-a'));
    await session.ingest(message('fala-b'));
    await pumpEventQueue();

    player.holdAll = true;

    unawaited(session.playFromHistory('fala-a'));
    await pumpEventQueue();
    expect(session.nowPlayingId, 'fala-a');

    unawaited(session.playFromHistory('fala-b'));
    await pumpEventQueue();
    expect(session.nowPlayingId, 'fala-b');

    // A termina agora, encerrada por B ter começado.
    player.release('fala-a');
    await pumpEventQueue();

    expect(session.nowPlayingId, 'fala-b',
        reason: 'o fim de A não pode apagar a marca de B');

    player.releaseAll();
    await pumpEventQueue();
    expect(session.nowPlayingId, isNull, reason: 'B terminou, agora é silêncio');
  });


  test('o histórico é um stream só, não um novo a cada leitura', () {
    // A tela lê `session.messages` dentro do `build`, e o `build` roda a cada
    // `setState` — e há um `setState` por fala baixada e por fala tocada. Um
    // stream novo a cada leitura faz o StreamBuilder reassinar e voltar à
    // snapshot vazia: a lista pisca, e o destaque de quem está falando some
    // junto, bem quando uma fala nova chega.
    expect(identical(session.messages, session.messages), isTrue);
  });


  test('a fala que chega no meio espera a anterior terminar', () async {
    // Uma voz por vez, nunca sobreposta: é a primeira invariante da spec. Uma
    // rajada de 12 s chega em três mensagens espaçadas de 5 s, que é
    // exatamente a duração de cada segmento — a fala seguinte chega no
    // instante em que a anterior está acabando, e é aí que a serialização é
    // testada de verdade.
    player.holdAll = true;

    await session.ingest(message('seg-um'));
    await pumpEventQueue();
    expect(player.played, hasLength(1), reason: 'a primeira começou');

    await session.ingest(message('seg-dois'));
    await pumpEventQueue();
    expect(player.played, hasLength(1),
        reason: 'a segunda não pode começar com a primeira ainda tocando');

    player.release('seg-um');
    await pumpEventQueue();
    expect(player.played, hasLength(2), reason: 'agora sim a segunda toca');

    player.releaseAll();
    await pumpEventQueue();
  });

}
