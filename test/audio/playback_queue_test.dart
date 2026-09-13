import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/playback_queue.dart';
import 'package:flycomm/room/budgets.dart';
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
  late List<String> played;
  late List<String> dropped;
  late int concurrentPlays;
  late int maxConcurrentPlays;
  PlaybackQueue? open;

  /// Toca "instantaneamente" por padrão; os testes que precisam de duração
  /// passam um [advance] que empurra o relógio.
  PlaybackQueue build({Duration advance = Duration.zero}) {
    final queue = PlaybackQueue(
      clock: clock,
      budgets: budgets,
      play: (item) async {
        concurrentPlays++;
        maxConcurrentPlays =
            concurrentPlays > maxConcurrentPlays ? concurrentPlays : maxConcurrentPlays;
        await Future<void>.delayed(Duration.zero);
        fakeNow = fakeNow.add(advance);
        played.add(item.messageId);
        concurrentPlays--;
      },
    );
    queue.dropped.listen((item) => dropped.add(item.messageId));
    open = queue;
    return queue;
  }

  /// `drained` só diz que o laço de reprodução parou. O stream de descarte é
  /// broadcast e entrega em microtask, então observar um descarte exige ceder
  /// o laço de eventos uma vez. Sem isto, todo teste que espera um item em
  /// [dropped] falha — e o evento ainda aparece no teste SEGUINTE.
  Future<void> settle(PlaybackQueue queue) async {
    await queue.drained;
    await Future<void>.delayed(Duration.zero);
  }

  /// A idade é a DA FALA: desde a 2.1 a entrega pode ser atrasada, e aí o
  /// carimbo do servidor mede o tempo errado.
  QueuedItem itemAgedBy(String id, Duration age) => QueuedItem(
        messageId: id,
        spokenAt: clock.now().subtract(age),
      );

  setUp(() {
    fakeNow = DateTime.utc(2026, 9, 13, 16, 0, 0);
    clock = ServerClock(localNow: () => fakeNow)
      ..sync(serverTime: fakeNow, receivedAt: fakeNow);
    played = [];
    dropped = [];
    concurrentPlays = 0;
    maxConcurrentPlays = 0;
    open = null;
  });

  // Fecha o controlador: sem isto, um descarte entregue tarde cai na lista do
  // teste seguinte e o diagnóstico fica ilegível.
  tearDown(() async => open?.dispose());

  test('FIFO estrito: em ordem de chegada, nunca sobreposta', () async {
    final queue = build();

    queue.enqueue(itemAgedBy('a', const Duration(seconds: 1)));
    queue.enqueue(itemAgedBy('b', const Duration(seconds: 1)));
    queue.enqueue(itemAgedBy('c', const Duration(seconds: 1)));
    await settle(queue);

    expect(played, ['a', 'b', 'c']);
    expect(maxConcurrentPlays, 1, reason: 'uma voz por vez');
  });

  test('item além do prazo sai da fila SEM tocar', () async {
    final queue = build();

    queue.enqueue(itemAgedBy('fresca', const Duration(seconds: 5)));
    queue.enqueue(itemAgedBy('vencida', const Duration(seconds: 31)));
    await settle(queue);

    expect(played, ['fresca']);
    expect(dropped, ['vencida'],
        reason: 'vira "atrasada" no histórico, ouvível por toque, nunca '
            'automaticamente');
  });

  test('a cauda que vence esperando a vez também é descartada', () async {
    // Cada reprodução consome 20 s do relógio do servidor.
    final queue = build(advance: const Duration(seconds: 20));

    queue.enqueue(itemAgedBy('primeira', Duration.zero));
    queue.enqueue(itemAgedBy('segunda', Duration.zero));
    queue.enqueue(itemAgedBy('terceira', Duration.zero));
    await settle(queue);

    // primeira toca em t=0; segunda em t=20 (idade 20 s, ainda fresca);
    // terceira em t=40, idade 40 s > 30 s.
    expect(played, ['primeira', 'segunda']);
    expect(dropped, ['terceira'],
        reason: 'uma fila que só cresce é bug, não backlog');
  });

  test('meio-duplex: com o PTT acionado, nada toca', () async {
    final queue = build();

    queue.pttHeld = true;
    queue.enqueue(itemAgedBy('a', const Duration(seconds: 1)));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(played, isEmpty);
    expect(dropped, isEmpty, reason: 'a fila acumula, não descarta');

    queue.pttHeld = false;
    await settle(queue);

    expect(played, ['a']);
  });

  test('soltar o PTT depois do prazo descarta o que venceu esperando', () async {
    final queue = build();

    queue.pttHeld = true;
    queue.enqueue(itemAgedBy('a', const Duration(seconds: 1)));

    fakeNow = fakeNow.add(const Duration(seconds: 40));
    queue.pttHeld = false;
    await settle(queue);

    expect(played, isEmpty);
    expect(dropped, ['a']);
  });

  test('acionar o PTT no meio da fila para a fila depois do item atual', () async {
    final queue = build();

    queue.enqueue(itemAgedBy('a', Duration.zero));
    queue.enqueue(itemAgedBy('b', Duration.zero));
    queue.pttHeld = true;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(played.length, lessThanOrEqualTo(1));
    expect(played, isNot(contains('b')));

    queue.pttHeld = false;
    await settle(queue);

    expect(played, contains('b'));
  });

  test('um item exatamente no prazo ainda toca', () async {
    final queue = build();

    queue.enqueue(itemAgedBy('limite', const Duration(seconds: 30)));
    await settle(queue);

    expect(played, ['limite']);
  });
}
