import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/segmenter.dart';
import 'package:flycomm/audio/wav.dart';

void main() {
  // 5 s de teto, o valor que GET /config devolve hoje.
  PcmSegmenter build() =>
      PcmSegmenter(segmentMax: const Duration(seconds: 5));

  /// Um pedaço de microfone de [ms] milissegundos, com bytes distinguíveis.
  Uint8List chunk(int ms, int seed) => Uint8List.fromList(
      List.generate(ms * bytesPerMs, (i) => (seed + i) % 256));

  test('uma fala de 12 s vira três mensagens', () {
    final segmenter = build();
    final closed = <Uint8List>[];

    // 120 pedaços de 100 ms = 12 s, como o microfone entrega.
    for (var i = 0; i < 120; i++) {
      closed.addAll(segmenter.add(chunk(100, i)));
    }
    final tail = segmenter.close();

    expect(closed, hasLength(2), reason: 'dois segmentos cheios de 5 s');
    expect(tail, isNotNull);
    expect(durationMsOfPcm(tail!.length), 2000, reason: 'e uma cauda de 2 s');
    expect(closed.length + 1, 3);
  });

  test('o corte é no metadado, nunca no áudio: nenhum byte se perde', () {
    final segmenter = build();
    final fed = <int>[];
    final out = <int>[];

    for (var i = 0; i < 120; i++) {
      final piece = chunk(100, i);
      fed.addAll(piece);
      for (final segment in segmenter.add(piece)) {
        out.addAll(segment);
      }
    }
    final tail = segmenter.close();
    if (tail != null) out.addAll(tail);

    expect(out, equals(fed),
        reason: 'ao fechar um segmento a captura não para, e o que sobrou do '
            'pedaço vai para o segmento seguinte');
  });

  test('cada segmento cheio tem exatamente o teto de duração', () {
    final segmenter = build();
    final closed = <Uint8List>[];

    for (var i = 0; i < 120; i++) {
      closed.addAll(segmenter.add(chunk(100, i)));
    }

    for (final segment in closed) {
      expect(durationMsOfPcm(segment.length), 5000);
    }
  });

  test('um pedaço grande fecha vários segmentos de uma vez', () {
    final segmenter = build();

    final closed = segmenter.add(chunk(16000, 0)); // 16 s de uma vez

    expect(closed, hasLength(3));
    expect(durationMsOfPcm(segmenter.close()!.length), 1000);
  });

  test('uma fala mais curta que o teto vira uma mensagem só', () {
    final segmenter = build();

    expect(segmenter.add(chunk(1200, 0)), isEmpty);

    final tail = segmenter.close();
    expect(durationMsOfPcm(tail!.length), 1200);
  });

  test('soltar o PTT sem ter falado não produz mensagem', () {
    expect(build().close(), isNull);
  });

  test('o teto vem do orçamento, não de uma constante', () {
    final segmenter = PcmSegmenter(segmentMax: const Duration(seconds: 2));

    final closed = segmenter.add(chunk(5000, 0));

    expect(closed, hasLength(2));
    expect(durationMsOfPcm(closed.first.length), 2000);
  });
}
