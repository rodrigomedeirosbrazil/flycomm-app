import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/wav.dart';

void main() {
  test('o cabeçalho tem 44 bytes e declara PCM 16 bits mono a 16 kHz', () {
    final header = wavHeader(dataBytes: 160000);

    expect(header.length, 44);

    final view = ByteData.sublistView(header);
    expect(String.fromCharCodes(header.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(header.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(header.sublist(12, 16)), 'fmt ');
    expect(view.getUint32(16, Endian.little), 16, reason: 'tamanho do bloco fmt');
    expect(view.getUint16(20, Endian.little), 1, reason: '1 = PCM, sem compressão');
    expect(view.getUint16(22, Endian.little), 1, reason: 'mono');
    expect(view.getUint32(24, Endian.little), 16000);
    expect(view.getUint32(28, Endian.little), 32000, reason: 'bytes por segundo');
    expect(view.getUint16(32, Endian.little), 2, reason: 'alinhamento de bloco');
    expect(view.getUint16(34, Endian.little), 16, reason: 'bits por amostra');
    expect(String.fromCharCodes(header.sublist(36, 40)), 'data');
    expect(view.getUint32(40, Endian.little), 160000);
    expect(view.getUint32(4, Endian.little), 36 + 160000);
  });

  test('um segmento de 5 s dá ~160 KB, como a spec diz', () {
    expect(bytesPerMs, 32);

    final dataBytes = 5000 * bytesPerMs;
    final file = wrapPcmInWav(Uint8List(dataBytes));

    expect(file.length, 44 + 160000);
    expect(file.length / 1024, closeTo(156.3, 0.1));
  });

  test('o PCM sai do WAV byte a byte igual ao que entrou', () {
    final pcm = Uint8List.fromList(List.generate(1000, (i) => i % 256));

    final file = wrapPcmInWav(pcm);

    expect(file.sublist(44), pcm);
  });

  test('a duração sai da contagem de bytes, não de um relógio', () {
    expect(durationMsOfPcm(160000), 5000);
    expect(durationMsOfPcm(32000), 1000);
    expect(durationMsOfPcm(0), 0);
  });
}
