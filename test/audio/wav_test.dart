import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/wav.dart';

/// PCM 16 bits little-endian a partir de amostras assinadas.
Uint8List pcmOf(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

void main() {
  group('peakAmplitudeOfPcm', () {
    test('silêncio digital dá zero', () {
      // Este é o caso que importa: duração e tamanho de um segmento mudo são
      // idênticos aos de um segmento com fala, porque saem da contagem de
      // bytes. Só a amplitude distingue os dois.
      expect(peakAmplitudeOfPcm(pcmOf(List.filled(1000, 0))), 0);
    });

    test('pega o pico independente do sinal', () {
      expect(peakAmplitudeOfPcm(pcmOf([0, 120, -3000, 40])), 3000);
    });

    test('o mínimo do int16 não estoura ao ser negado', () {
      // -32768 não tem oposto em int16: negar dá -32768 de novo. Um `-min`
      // ingênuo devolveria um pico negativo, e a checagem de mudez passaria
      // a dizer que o segmento mais alto possível é o mais silencioso.
      expect(peakAmplitudeOfPcm(pcmOf([-32768, 5])), 32768);
    });

    test('buffer vazio não estoura', () {
      expect(peakAmplitudeOfPcm(Uint8List(0)), 0);
    });

    test('byte solto no fim é ignorado, não lido pela metade', () {
      // Um stream cortado pode entregar um número ímpar de bytes. Ler o
      // último sozinho inventaria uma amostra que não existe.
      final truncated = Uint8List.fromList([...pcmOf([1000]), 0x7f]);
      expect(peakAmplitudeOfPcm(truncated), 1000);
    });
  });
}
