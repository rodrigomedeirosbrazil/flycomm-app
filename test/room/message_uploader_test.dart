import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/history/database.dart';
import 'package:flycomm/history/history_repository.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/budgets.dart';
import 'package:flycomm/room/message_api.dart';
import 'package:flycomm/room/message_uploader.dart';
import 'package:flycomm/room/models.dart';
import 'package:flycomm/room/server_clock.dart';

void main() {
  const budgets = Budgets(
    playbackDeadline: Duration(seconds: 30),
    radioRelayDeadline: Duration(seconds: 10),
    deliveryDeadline: Duration(minutes: 5),
    segmentMax: Duration(seconds: 5),
    catchupWindow: Duration(seconds: 60),
    blobTtl: Duration(minutes: 5),
  );

  late DateTime fakeNow;
  late ServerClock clock;
  late HistoryDatabase db;
  late HistoryRepository history;

  setUp(() async {
    fakeNow = DateTime.utc(2026, 9, 13, 16, 0, 0);
    clock = ServerClock(localNow: () => fakeNow)
      ..sync(serverTime: fakeNow, receivedAt: fakeNow);
    db = HistoryDatabase(NativeDatabase.memory());
    history = HistoryRepository(db);
  });

  tearDown(() => db.close());

  OutgoingSegment segment({String id = 'msg-1', DateTime? capturedAt}) =>
      OutgoingSegment(
        id: id,
        roomId: 255,
        burstId: 'burst-1',
        index: 0,
        durationMs: 5000,
        capturedAt: capturedAt ?? fakeNow,
        wavBytes: Uint8List(44),
      );

  /// O que o servidor devolve: `createdAt` é o instante em que ele recebeu, que
  /// não é o instante em que a fala aconteceu.
  RoomMessage accepted(OutgoingSegment s) => RoomMessage(
        id: s.id,
        roomId: s.roomId,
        burstId: s.burstId,
        index: s.index,
        authorId: 509,
        authorName: 'Rodrigo',
        durationMs: s.durationMs,
        origin: 'app',
        format: 'wav-pcm16-16k',
        sizeBytes: 160044,
        capturedAt: s.capturedAt,
        createdAt: clock.now().add(const Duration(milliseconds: 200)),
        expiresAt: clock.now().add(const Duration(minutes: 5)),
        audioUrl: 'http://servidor/messages/${s.id}/audio',
      );

  Future<void> recordIt(OutgoingSegment s) => history.recordOutgoing(
        id: s.id,
        roomId: s.roomId,
        burstId: s.burstId,
        index: s.index,
        durationMs: s.durationMs,
        format: MessageApi.format,
        capturedAt: s.capturedAt,
        audioPath: '/tmp/${s.id}.wav',
      );

  MessageUploader build(Future<RoomMessage> Function(OutgoingSegment) publish) =>
      MessageUploader(
        clock: clock,
        budgets: budgets,
        history: history,
        publish: publish,
        // Em vez de dormir de verdade, a espera empurra o relógio falso.
        wait: (d) async => fakeNow = fakeNow.add(d),
      );

  test('sucesso de primeira: gravada → enviando → entregue', () async {
    final s = segment();
    await recordIt(s);

    await build((seg) async => accepted(seg)).upload(s);

    final row = (await history.byId('msg-1'))!;
    expect(row.state, MessageState.delivered);
    expect(row.createdAt, isNotNull);
  });

  test('insiste enquanto a janela de entrega não fecha', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((seg) async {
      attempts++;
      if (attempts < 3) {
        throw ApiException(statusCode: null, message: 'sem rede');
      }
      return accepted(seg);
    }).upload(s);

    expect(attempts, 3);
    expect((await history.byId('msg-1'))!.state, MessageState.delivered);
  });

  test('a fala vencida sobe assim mesmo, e entra como entregue atrasada', () async {
    // Gravada sem rede há dois minutos; a rede voltou agora. Ninguém vai ouvir
    // isto ao vivo, mas o registro entra no histórico de todo mundo — sem isso,
    // quem ficou sem rede some do histórico dos outros sem deixar indício.
    final s = segment(capturedAt: fakeNow.subtract(const Duration(minutes: 2)));
    await recordIt(s);
    var attempts = 0;

    await build((seg) async {
      attempts++;
      return accepted(seg);
    }).upload(s);

    expect(attempts, 1, reason: 'passou do prazo de reprodução, não do de entrega');

    final row = (await history.byId('msg-1'))!;
    expect(row.state, MessageState.deliveredLate,
        reason: 'entrou no histórico dos outros, mas ninguém ouviu ao vivo');
    expect(row.createdAt, isNotNull);
  });

  test('passada a janela de entrega, desiste e marca NÃO ENTREGUE', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      throw ApiException(statusCode: null, message: 'sem rede');
    }).upload(s);

    expect(attempts, greaterThan(1));
    expect(clock.now().difference(s.capturedAt),
        greaterThanOrEqualTo(budgets.deliveryDeadline));

    final row = (await history.byId('msg-1'))!;
    expect(row.state, MessageState.undelivered,
        reason: 'a informação de que o piloto precisa é que ninguém o ouviu');
    expect(row.createdAt, isNull);
    expect(row.audioPath, isNotNull,
        reason: 'o histórico é permanente mesmo quando a mensagem não saiu');
  });

  test('o que já nasceu fora da janela de entrega não tenta nem uma vez', () async {
    final s = segment(capturedAt: fakeNow.subtract(const Duration(minutes: 10)));
    await recordIt(s);
    var attempts = 0;

    await build((seg) async {
      attempts++;
      return accepted(seg);
    }).upload(s);

    expect(attempts, 0,
        reason: 'o teto é o que impede a entrega atrasada de virar fila de '
            'saída persistente');
    expect((await history.byId('msg-1'))!.state, MessageState.undelivered);
  });

  test('422 não é retentado: o servidor recusou o conteúdo, não a rede', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      throw ApiException(statusCode: 422, message: 'captured_at implausível');
    }).upload(s);

    expect(attempts, 1);
    expect((await history.byId('msg-1'))!.state, MessageState.undelivered);
  });

  test('409 não é retentado: o id pertence a outra sala', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      throw ApiException(statusCode: 409, message: 'id de outra sala');
    }).upload(s);

    expect(attempts, 1);
    expect((await history.byId('msg-1'))!.state, MessageState.undelivered);
  });

  test('fresco na frente: o atrasado cede a rede para quem ainda pode ser ouvido',
      () async {
    final velha = segment(
      id: 'velha',
      capturedAt: fakeNow.subtract(const Duration(minutes: 1)),
    );
    final nova = segment(id: 'nova');
    await recordIt(velha);
    await recordIt(nova);

    final order = <String>[];
    final uploader = build((seg) async {
      order.add(seg.id);
      return accepted(seg);
    });

    // As duas entram na fila antes de a primeira rodada escolher. A `velha`
    // chegou primeiro e mesmo assim espera: ela não pode mais ser ouvida ao
    // vivo, e a `nova` ainda pode.
    final velhaDone = uploader.upload(velha);
    final novaDone = uploader.upload(nova);
    await Future.wait([velhaDone, novaDone]);

    expect(order, ['nova', 'velha']);
    expect((await history.byId('nova'))!.state, MessageState.delivered);
    expect((await history.byId('velha'))!.state, MessageState.deliveredLate);
  });

  test('um fresco que falha para de segurar a fila quando deixa de ser fresco',
      () async {
    final primeira = segment(id: 'primeira');
    await recordIt(primeira);

    final order = <String>[];
    final uploader = build((seg) async {
      order.add(seg.id);
      // A primeira nunca sobe; a segunda sobe de primeira.
      if (seg.id == 'primeira') {
        throw ApiException(statusCode: null, message: 'sem rede');
      }
      return accepted(seg);
    });

    final primeiraDone = uploader.upload(primeira);

    // O backoff empurra o relógio falso; em algum momento a `primeira` passa
    // dos 30 s e deixa de ser fresca. A `segunda` é gravada nesse ponto.
    await Future<void>.delayed(Duration.zero);
    final segunda = segment(id: 'segunda', capturedAt: clock.now());
    await recordIt(segunda);
    await uploader.upload(segunda);

    expect(order.last, 'segunda',
        reason: 'a conversa do presente não espera o registro do passado');
    expect((await history.byId('segunda'))!.state, MessageState.delivered);

    await primeiraDone;
    expect((await history.byId('primeira'))!.state, MessageState.undelivered);
  });
}
