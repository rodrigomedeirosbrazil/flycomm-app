import 'dart:typed_data';

import 'wav.dart';

/// Fecha um segmento a cada [segmentMax] de áudio acumulado.
///
/// O corte é no metadado, nunca no áudio: [add] devolve os segmentos que este
/// pedaço fechou e guarda o resto para o próximo. Quem chama nunca para a
/// captura por causa de um fechamento.
///
/// O teto vem de `segment_max_ms` em GET /config, não de uma constante — e o
/// servidor recusa `duration_ms` acima dele, o que faz a regra de 5 s ser do
/// sistema e não só do app.
class PcmSegmenter {
  PcmSegmenter({required Duration segmentMax})
      : maxBytes = segmentMax.inMilliseconds * bytesPerMs;

  final int maxBytes;

  Uint8List _pending = Uint8List(0);

  List<Uint8List> add(Uint8List chunk) {
    final merged = Uint8List(_pending.length + chunk.length)
      ..setAll(0, _pending)
      ..setAll(_pending.length, chunk);

    final closed = <Uint8List>[];
    var offset = 0;

    while (merged.length - offset >= maxBytes) {
      closed.add(Uint8List.sublistView(merged, offset, offset + maxBytes));
      offset += maxBytes;
    }

    _pending = Uint8List.sublistView(merged, offset);

    return closed;
  }

  /// O último segmento, parcial, quando o piloto solta o PTT. Nulo se ele não
  /// chegou a falar nada.
  Uint8List? close() {
    if (_pending.isEmpty) return null;

    final tail = _pending;
    _pending = Uint8List(0);

    return tail;
  }
}
