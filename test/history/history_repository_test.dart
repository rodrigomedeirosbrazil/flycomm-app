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

  RoomMessage incoming(
    String id, {
    int index = 0,
    String burst = 'b-1',
    DateTime? capturedAt,
    DateTime? createdAt,
    String origin = 'app',
  }) =>
      RoomMessage(
        id: id,
        roomId: 255,
        burstId: burst,
        index: index,
        authorId: 510,
        authorName: 'Marina',
        durationMs: 5000,
        origin: origin,
        format: 'wav-pcm16-16k',
        sizeBytes: 160044,
        capturedAt: origin == 'radio'
            ? null
            : capturedAt ?? DateTime.utc(2026, 9, 13, 16),
        createdAt: createdAt ?? DateTime.utc(2026, 9, 13, 16, 0, 1),
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

  test('chegar não é ter sido ouvida', () async {
    // A mensagem entra como `received` no instante em que chega, antes de
    // entrar na fila. Se "já ouvi isto?" fosse lida do estado, tudo o que
    // chegasse pareceria ouvido.
    await history.recordIncoming(incoming('p-1'), MessageState.received);
    expect((await history.byId('p-1'))!.played, isFalse);

    await history.markPlayed('p-1');
    expect((await history.byId('p-1'))!.played, isTrue);
  });

  test('ouvir uma atrasada por toque não a torna pontual', () async {
    await history.recordIncoming(incoming('p-2'), MessageState.late);

    await history.markHeard('p-2');
    final row = (await history.byId('p-2'))!;

    expect(row.played, isTrue);
    expect(row.state, MessageState.late,
        reason: 'ela não tocou ao vivo, e isso não deixa de ser verdade '
            'porque o piloto foi ouvi-la depois');
  });

  test('a tela recebe a mais nova primeiro, para desenhar de trás para frente',
      () async {
    await history.recordIncoming(
        incoming('w-1', capturedAt: DateTime.utc(2026, 9, 13, 16)),
        MessageState.received);
    await history.recordIncoming(
        incoming('w-3', capturedAt: DateTime.utc(2026, 9, 13, 16, 2)),
        MessageState.received);
    await history.recordIncoming(
        incoming('w-2', capturedAt: DateTime.utc(2026, 9, 13, 16, 1)),
        MessageState.received);

    final rows = await history.watchRoom(255).first;

    expect(rows.map((r) => r.id), ['w-3', 'w-2', 'w-1']);
    expect(rows.map((r) => r.id).toList().reversed,
        (await history.forRoom(255)).map((r) => r.id),
        reason: 'invertida, é exatamente a ordem cronológica de forRoom — '
            'duas ordens diferentes para o mesmo histórico seria bug');
  });

  test('o sucesso depois do prazo é entregue atrasada, não entregue', () async {
    await history.recordOutgoing(
      id: 'out-3',
      roomId: 255,
      burstId: 'b-out',
      index: 0,
      durationMs: 5000,
      format: 'wav-pcm16-16k',
      capturedAt: DateTime.utc(2026, 9, 13, 16),
      audioPath: '/tmp/out-3.wav',
    );

    await history.markDelivered('out-3', incoming('out-3'), wasLate: true);

    final row = (await history.byId('out-3'))!;
    expect(row.state, MessageState.deliveredLate,
        reason: 'ficou no registro dos outros, mas ninguém ouviu ao vivo');
    expect(row.createdAt, isNotNull);
  });

  test('a mensagem atrasada entra onde foi gravada, não onde chegou', () async {
    // Duas falas: uma às 16:00 que só chegou às 16:03, e uma às 16:01 que
    // chegou na hora. A ordem da conversa é 16:00 e depois 16:01.
    await history.recordIncoming(
      incoming(
        'atrasada',
        capturedAt: DateTime.utc(2026, 9, 13, 16, 0, 0),
        createdAt: DateTime.utc(2026, 9, 13, 16, 3, 0),
      ),
      MessageState.late,
    );
    await history.recordIncoming(
      incoming(
        'na-hora',
        burst: 'b-2',
        capturedAt: DateTime.utc(2026, 9, 13, 16, 1, 0),
        createdAt: DateTime.utc(2026, 9, 13, 16, 1, 0),
      ),
      MessageState.received,
    );

    final rows = await history.forRoom(255);

    expect(rows.map((r) => r.id), ['atrasada', 'na-hora'],
        reason: 'ordenar pela chegada contaria uma história errada sobre a '
            'ordem em que as coisas foram ditas');
  });

  test('origem rádio, sem captured_at, se posiciona pela chegada', () async {
    await history.recordIncoming(
      incoming(
        'do-radio',
        origin: 'radio',
        createdAt: DateTime.utc(2026, 9, 13, 16, 2, 0),
      ),
      MessageState.received,
    );

    final row = (await history.byId('do-radio'))!;
    expect(row.capturedAt, isNull, reason: 'não há cliente ali para carimbar');
    expect(row.recordedAt.toUtc(), DateTime.utc(2026, 9, 13, 16, 2, 0));
  });

  test('a última mensagem vista é o since do catch-up', () async {
    expect(await history.lastSeenAt(255), isNull);

    await history.recordIncoming(incoming('t-1'), MessageState.received);

    expect(await history.lastSeenAt(255), DateTime.utc(2026, 9, 13, 16, 0, 1),
        reason: 'o since é carimbo do servidor, não a idade da fala: o '
            'transporte continua ordenado por createdAt');
  });
}
