import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/history/database.dart';
import 'package:flycomm/history/replay.dart';

void main() {
  /// `watchRoom` devolve do mais novo para o mais velho — é o que dá o
  /// autoscroll de graça na tela, com `reverse: true`.
  LocalMessage segment(
    String id, {
    required String burst,
    required int index,
    required DateTime recordedAt,
    MessageDirection direction = MessageDirection.incoming,
    String? audioPath = '/tmp/a.wav',
  }) =>
      LocalMessage(
        id: id,
        roomId: 255,
        burstId: burst,
        segmentIndex: index,
        authorId: 510,
        authorName: 'Marina',
        durationMs: 5000,
        origin: 'app',
        format: 'wav-pcm16-16k',
        capturedAt: recordedAt,
        createdAt: recordedAt,
        direction: direction,
        state: MessageState.received,
        played: false,
        audioPath: audioPath,
        recordedAt: recordedAt,
      );

  final base = DateTime.utc(2026, 9, 14, 12);

  test('devolve os três segmentos da rajada, em ordem crescente', () {
    final rows = [
      segment('c', burst: 'b-1', index: 2, recordedAt: base.add(const Duration(seconds: 10))),
      segment('b', burst: 'b-1', index: 1, recordedAt: base.add(const Duration(seconds: 5))),
      segment('a', burst: 'b-1', index: 0, recordedAt: base),
    ];

    expect(lastIncomingBurst(rows).map((m) => m.id), ['a', 'b', 'c']);
  });

  test('pega a rajada mais nova, não a anterior', () {
    final rows = [
      segment('nova', burst: 'b-2', index: 0, recordedAt: base.add(const Duration(minutes: 1))),
      segment('velha', burst: 'b-1', index: 0, recordedAt: base),
    ];

    expect(lastIncomingBurst(rows).map((m) => m.id), ['nova']);
  });

  test('ignora a própria fala do piloto', () {
    // "Diga de novo" é sobre o que o outro disse. A própria fala o piloto
    // acabou de dizer.
    final rows = [
      segment('minha',
          burst: 'b-2',
          index: 0,
          recordedAt: base.add(const Duration(minutes: 1)),
          direction: MessageDirection.outgoing),
      segment('dele', burst: 'b-1', index: 0, recordedAt: base),
    ];

    expect(lastIncomingBurst(rows).map((m) => m.id), ['dele']);
  });

  test('ignora segmento sem áudio no aparelho', () {
    // O blob vence no servidor em minutos. Um segmento que não baixou a tempo
    // não toca, e a rajada toca sem ele: parcial é melhor que nada, e a linha
    // do histórico já mostra que falta.
    final rows = [
      segment('b', burst: 'b-1', index: 1, recordedAt: base.add(const Duration(seconds: 5))),
      segment('a', burst: 'b-1', index: 0, recordedAt: base, audioPath: null),
    ];

    expect(lastIncomingBurst(rows).map((m) => m.id), ['b']);
  });

  test('sem nada recebido, devolve vazio', () {
    expect(lastIncomingBurst(const []), isEmpty);
  });
}
