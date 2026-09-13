import 'dart:typed_data';

const sampleRate = 16000;
const channels = 1;
const bitsPerSample = 16;

/// PCM 16 bits mono a 16 kHz: 32 bytes por milissegundo. É deste número que
/// saem o teto do segmento e a duração de cada mensagem — a duração vem da
/// contagem de bytes, nunca de um cronômetro, que derrapa.
const bytesPerMs = sampleRate * channels * (bitsPerSample ~/ 8) ~/ 1000;

int durationMsOfPcm(int pcmBytes) => pcmBytes ~/ bytesPerMs;

/// Cabeçalho RIFF de 44 bytes. O servidor trata áudio como bytes opacos, então
/// trocar WAV por Opus ou AAC depois não toca no backend nem no schema — só
/// aqui e no campo `format`.
Uint8List wavHeader({required int dataBytes}) {
  const byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  const blockAlign = channels * bitsPerSample ~/ 8;

  final header = Uint8List(44);
  final view = ByteData.sublistView(header);

  void ascii(int offset, String text) {
    header.setRange(offset, offset + text.length, text.codeUnits);
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // 1 = PCM, sem compressão
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, byteRate, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, dataBytes, Endian.little);

  return header;
}

Uint8List wrapPcmInWav(Uint8List pcm) {
  final header = wavHeader(dataBytes: pcm.length);
  final file = Uint8List(header.length + pcm.length)
    ..setAll(0, header)
    ..setAll(header.length, pcm);

  return file;
}

/// O pico absoluto das amostras, de 0 a 32768. Zero é silêncio digital: não
/// "baixinho", mas literalmente nenhuma amostra diferente de zero.
///
/// Existe porque `duration_ms` e `size_bytes` saem da contagem de bytes e são
/// **idênticos** para um segmento com fala e um segmento mudo. Uma gravação que
/// não captou nada chega ao servidor com metadado impecável. Sem medir a
/// amplitude, "o áudio do Android está mudo" não tem como ser distinguido de
/// "o áudio não está tocando no receptor" — são falhas em pontas opostas da
/// cadeia com exatamente o mesmo rastro.
int peakAmplitudeOfPcm(Uint8List pcm) {
  final view = ByteData.sublistView(pcm);

  // Um stream cortado pode entregar um número ímpar de bytes; o byte solto no
  // fim não é uma amostra e ler ele sozinho inventaria uma.
  final samples = pcm.lengthInBytes ~/ 2;

  var peak = 0;
  for (var i = 0; i < samples; i++) {
    // `abs()` e não `-v`: -32768 não tem oposto em int16 e negar devolveria
    // -32768, fazendo o segmento mais alto possível parecer o mais silencioso.
    final magnitude = view.getInt16(i * 2, Endian.little).abs();
    if (magnitude > peak) peak = magnitude;
  }

  return peak;
}
