import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/history/database.dart';
import 'package:flycomm/history/history_repository.dart';
import 'package:flycomm/room/models.dart';

void main() {
  late HistoryDatabase db;
  late HistoryRepository history;

  setUp(() {
    db = HistoryDatabase(NativeDatabase.memory());
    history = HistoryRepository(db);
  });

  tearDown(() => db.close());

  RoomMessage incoming(String id, {int index = 0, String burst = 'b-1'}) =>
      RoomMessage(
        id: id,
        roomId: 255,
        burstId: burst,
        index: index,
        authorId: 510,
        authorName: 'Marina',
        durationMs: 5000,
        origin: 'app',
        format: 'wav-pcm16-16k',
        sizeBytes: 160044,
        capturedAt: DateTime.utc(2026, 9, 13, 16),
        createdAt: DateTime.utc(2026, 9, 13, 16, 0, 1),
        expiresAt: DateTime.utc(2026, 9, 13, 16, 5, 1),
        audioUrl: 'http://servidor/messages/$id/audio',
      );

  test('a mensagem de saída percorre gravada → enviando → entregue', () async {
    await history.recordOutgoing(
      id: 'out-1',
      roomId: 255,
      burstId: 'b-out',
      index: 0,
      durationMs: 5000,
      format: 'wav-pcm16-16k',
      capturedAt: DateTime.utc(2026, 9, 13, 16),
      audioPath: '/tmp/out-1.wav',
    );
    expect((await history.byId('out-1'))!.state, MessageState.recorded);

    await history.markSending('out-1');
    expect((await history.byId('out-1'))!.state, MessageState.sending);

    await history.markDelivered('out-1', incoming('out-1'));
    final delivered = (await history.byId('out-1'))!;
    expect(delivered.state, MessageState.delivered);
    expect(delivered.createdAt, isNotNull,
        reason: 'só o servidor emite createdAt, e só quando aceita a mensagem');
  });

  test('a mensagem não entregue guarda o áudio e não ganha createdAt', () async {
    await history.recordOutgoing(
      id: 'out-2',
      roomId: 255,
      burstId: 'b-out',
      index: 0,
      durationMs: 3000,
      format: 'wav-pcm16-16k',
      capturedAt: DateTime.utc(2026, 9, 13, 16),
      audioPath: '/tmp/out-2.wav',
    );
    await history.markUndelivered('out-2');

    final row = (await history.byId('out-2'))!;
    expect(row.state, MessageState.undelivered);
    expect(row.createdAt, isNull);
    expect(row.audioPath, '/tmp/out-2.wav',
        reason: 'o áudio fica no dispositivo: o histórico é permanente mesmo '
            'quando ninguém ouviu');
  });

  test('gravar a mesma mensagem duas vezes não duplica', () async {
    await history.recordIncoming(incoming('in-1'), MessageState.received);
    await history.recordIncoming(incoming('in-1'), MessageState.received);

    expect(await history.countForRoom(255), 1);
  });

  test('mensagem que venceu na fila entra como atrasada', () async {
    await history.recordIncoming(incoming('in-2'), MessageState.late);

    expect((await history.byId('in-2'))!.state, MessageState.late);
  });

  test('o histórico da sala vem em ordem de rajada e índice', () async {
    await history.recordIncoming(incoming('s-2', index: 1), MessageState.received);
    await history.recordIncoming(incoming('s-1', index: 0), MessageState.received);
    await history.recordIncoming(incoming('s-3', index: 2), MessageState.received);

    final rows = await history.forRoom(255);

    expect(rows.map((r) => r.id), ['s-1', 's-2', 's-3'],
        reason: 'os três segmentos de uma fala de 12 s aparecem em ordem');
  });

  test('a última mensagem vista é o since do catch-up', () async {
    expect(await history.lastSeenAt(255), isNull);

    await history.recordIncoming(incoming('t-1'), MessageState.received);

    expect(await history.lastSeenAt(255), DateTime.utc(2026, 9, 13, 16, 0, 1));
  });
}
