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

  OutgoingSegment segment({DateTime? capturedAt}) => OutgoingSegment(
        id: 'msg-1',
        roomId: 255,
        burstId: 'burst-1',
        index: 0,
        durationMs: 5000,
        capturedAt: capturedAt ?? fakeNow,
        wavBytes: Uint8List(44),
      );

  RoomMessage accepted() => RoomMessage(
        id: 'msg-1',
        roomId: 255,
        burstId: 'burst-1',
        index: 0,
        authorId: 509,
        authorName: 'Rodrigo',
        durationMs: 5000,
        origin: 'app',
        format: 'wav-pcm16-16k',
        sizeBytes: 160044,
        capturedAt: fakeNow,
        createdAt: fakeNow.add(const Duration(milliseconds: 200)),
        expiresAt: fakeNow.add(const Duration(minutes: 5)),
        audioUrl: 'http://servidor/messages/msg-1/audio',
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
        // Em vez de dormir de verdade, o backoff empurra o relógio falso.
        wait: (d) async => fakeNow = fakeNow.add(d),
      );

  test('sucesso de primeira: gravada → enviando → entregue', () async {
    final s = segment();
    await recordIt(s);

    await build((_) async => accepted()).upload(s);

    final row = (await history.byId('msg-1'))!;
    expect(row.state, MessageState.delivered);
    expect(row.createdAt, isNotNull);
  });

  test('insiste enquanto a janela de validade não fecha', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      if (attempts < 3) {
        throw ApiException(statusCode: null, message: 'sem rede');
      }
      return accepted();
    }).upload(s);

    expect(attempts, 3);
    expect((await history.byId('msg-1'))!.state, MessageState.delivered);
  });

  test('passada a janela, desiste e marca NÃO ENTREGUE', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      throw ApiException(statusCode: null, message: 'sem rede');
    }).upload(s);

    expect(attempts, greaterThan(1));
    expect(clock.now().difference(s.capturedAt),
        greaterThanOrEqualTo(budgets.playbackDeadline));

    final row = (await history.byId('msg-1'))!;
    expect(row.state, MessageState.undelivered,
        reason: 'a informação de que o piloto precisa é que ninguém o ouviu');
    expect(row.createdAt, isNull);
    expect(row.audioPath, isNotNull,
        reason: 'o histórico é permanente mesmo quando a mensagem não saiu');
  });

  test('422 não é retentado: o servidor recusou o conteúdo, não a rede', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      throw ApiException(statusCode: 422, message: 'duration_ms inválido');
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

  test('segmento que já nasceu vencido não tenta nem uma vez', () async {
    final s = segment(capturedAt: fakeNow.subtract(const Duration(minutes: 2)));
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      return accepted();
    }).upload(s);

    expect(attempts, 0, reason: 'gravado sem rede há dois minutos: ninguém '
        'tocaria isso, e insistir gasta bateria à toa');
    expect((await history.byId('msg-1'))!.state, MessageState.undelivered);
  });
}
