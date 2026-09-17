# Fase 1 no app — falar com o ESP32: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O app conecta no dispositivo ponte por BLE, negocia MTU, faz o handshake de reserva, empurra a config, e mede a vazão real do enlace nos dois sentidos — o número que decide se o desenho da Fase 1 se sustenta.

**Architecture:** Um módulo `lib/ble/` novo. A metade pura dele — codec, quadro do protocolo, control/state e reamostragem — é espelho byte a byte do firmware em `flycomm/src/`, e é testada com `flutter test` sem hardware nenhum. A metade que fala com o rádio fica num único arquivo por cima, e uma tela de bancada a exercita.

**Tech Stack:** Flutter 3.47.3, `flutter_blue_plus` (BLE central), `flutter_test`.

**Spec:** `docs/specs/2026-09-16-fase-1-ponte-ble-design.md` (espelhada na Task 0)

**Firmware correspondente:** `flycomm/src/{adpcm,chunk,control,device_config}.h` — são eles que este plano espelha. Em caso de divergência, **o firmware é a origem**.

---

## Escopo, e por que ele para onde para

Este plano entrega o app capaz de **conversar** com o dispositivo e de **medir** o enlace. Ele **não** liga o BLE na sala: nada de retransmitir fala para o ar, nada de enfileirar o áudio recebido na FIFO de reprodução, nada de eleição de ponte.

O motivo é o mesmo que fez o plano do firmware parar no Marco 6: a vazão do BLE é o risco nº 1 do projeto desde a primeira spec e continua sem número. Construir a integração com a sala agora seria construir em cima de uma estimativa. O que este plano entrega é exatamente a ferramenta que produz o número — e, de quebra, toda a lógica pura de que a integração vai precisar depois, já testada.

## Idioma

O módulo `lib/ble/` é escrito **inteiramente em inglês** — identificadores, comentários, mensagens. Ele é espelho dos arquivos `.h` do firmware, que são em inglês, e os dois precisam ser lidos lado a lado quando algo divergir.

Os módulos que já existem (`audio/`, `room/`, `history/`, `ui/`) **não são tocados** neste plano e mantêm o estilo deles.

## Estrutura de arquivos

| Arquivo | Responsabilidade | Espelha | Testável sem hardware? |
|---|---|---|---|
| `lib/ble/adpcm.dart` | IMA ADPCM, blocos autossuficientes | `src/adpcm.cpp` | **sim** |
| `lib/ble/chunk.dart` | cabeçalho de 8 bytes | `src/chunk.h` | **sim** |
| `lib/ble/control.dart` | `control` e `state` | `src/control.h` | **sim** |
| `lib/ble/resampler.dart` | 16 kHz → 8 kHz com filtro | — | **sim** |
| `lib/ble/bridge_link.dart` | varredura, conexão, MTU, characteristics | `src/link.cpp` | não |
| `lib/ble/bench.dart` | driver da medição de vazão | `bench/throughput_main.cpp` | não |
| `lib/ui/ble_bench_screen.dart` | a tela de bancada | — | não |

---

## Task 0: Espelhar a spec, adicionar a dependência e as permissões

**Files:**
- Create: `docs/specs/2026-09-16-fase-1-ponte-ble-design.md`
- Modify: `pubspec.yaml`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `ios/Runner/Info.plist`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Copiar a spec do repo canônico**

O `docs/specs/README.md` é explícito: estes arquivos são cópias **verbatim**, e a origem é o `flycomm`. Copiar, nunca reescrever.

```bash
cp ../flycomm/docs/superpowers/specs/2026-09-16-fase-1-ponte-ble-design.md docs/specs/
diff ../flycomm/docs/superpowers/specs/2026-09-16-fase-1-ponte-ble-design.md docs/specs/2026-09-16-fase-1-ponte-ble-design.md && echo "verbatim OK"
```

Expected: `verbatim OK`.

- [ ] **Step 2: Adicionar o `flutter_blue_plus`**

```bash
flutter pub add flutter_blue_plus
```

Expected: a versão resolvida aparece em `pubspec.yaml` e `pubspec.lock`.

**Anote a versão resolvida.** A Task 5 traz o código contra a API corrente do pacote, e a API dele já mudou entre versões maiores. Se algo não casar, o `flutter analyze` da Task 7 aponta, e a referência é a do pacote instalado em `~/.pub-cache`, não a memória de ninguém.

- [ ] **Step 3: Permissões do Android**

Em `android/app/src/main/AndroidManifest.xml`, adicionar dentro de `<manifest>` e antes de `<application>`:

```xml
    <!-- BLE central. neverForLocation because the bridge is a device we own and
         pair with deliberately: we are not using scan results to infer where the
         pilot is, and asking for location would be asking for more than we use. -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
```

`android:required="false"` no `uses-feature` é deliberado: quem só tem celular, sem ponte, continua sendo um participante de primeira classe do sistema (§1.1 da spec de 2026-09-12). Marcar como obrigatório esconderia o app da Play Store para aparelhos sem BLE sem nenhum ganho.

- [ ] **Step 4: Permissões do iOS**

Em `ios/Runner/Info.plist`, adicionar dentro do `<dict>` raiz:

```xml
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>O app usa Bluetooth para falar com o dispositivo que conecta o seu rádio VHF.</string>
```

O texto aparece para o piloto no diálogo do sistema, então ele é em português mesmo — é interface, não código.

- [ ] **Step 5: Registrar o módulo novo no `CLAUDE.md`**

O `CLAUDE.md` diz hoje: *"Os módulos `ble/`, `bridge/` e `background/` são das Fases 3 e 4 — não crie diretórios vazios para eles."* Isso deixou de valer para o `ble/`.

Na seção "## Módulos", substituir o parágrafo inteiro por:

```markdown
Da spec: `audio/`, `room/`, `history/`, `ui/`. O módulo `ble/` existe desde a
Fase 1 e conversa com o dispositivo ponte —
[docs/specs/2026-09-16-fase-1-ponte-ble-design.md](docs/specs/2026-09-16-fase-1-ponte-ble-design.md).
Os módulos `bridge/` e `background/` são das Fases 3 e 4 — não crie diretórios
vazios para eles.

**`lib/ble/` é escrito em inglês**, e a metade pura dele (`adpcm.dart`,
`chunk.dart`, `control.dart`) é **espelho** de `flycomm/src/{adpcm,chunk,control}.h`.
Divergir de um lado só produz ruído que soa como problema de rádio. Em caso de
conflito, o firmware é a origem.
```

- [ ] **Step 6: Commit**

```bash
git add docs/specs pubspec.yaml pubspec.lock android/app/src/main/AndroidManifest.xml ios/Runner/Info.plist CLAUDE.md
git commit -m "build: BLE dependency, permissions and the Phase 1 spec mirror"
```

---

## Task 1: ADPCM em Dart, batendo com o firmware byte a byte

O teste que importa aqui não é "o codec funciona". É **"o codec produz exatamente os mesmos bytes que o do ESP32"**. Duas implementações do mesmo algoritmo divergem em arredondamento e clamp, e a divergência não dá erro: ela sai como chiado no rádio, e se procura no lugar errado por dias.

Os 128 bytes abaixo vieram de `flycomm/test/fixtures/adpcm_golden.h`, que por sua vez saiu do codec em C já validado por dois testes de propriedade.

**Files:**
- Create: `lib/ble/adpcm.dart`
- Create: `test/ble/adpcm_test.dart`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ble/adpcm_test.dart`:

```dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/ble/adpcm.dart';

/// The exact input `golden_input()` builds in flycomm/test/test_adpcm/main.cpp:
/// a 440 Hz sine sampled at 8 kHz, amplitude 8000, 256 samples. C truncates
/// toward zero on the cast and so does Dart's toInt(), which is what makes the
/// two sides land on the same integers.
Int16List goldenInput() {
  final pcm = Int16List(256);
  for (var i = 0; i < 256; i++) {
    pcm[i] = (8000.0 * math.sin(2 * math.pi * 440.0 * i / 8000.0)).toInt();
  }
  return pcm;
}

/// Frozen output of flycomm/src/adpcm.cpp, copied from
/// flycomm/test/fixtures/adpcm_golden.h. This is the contract between the two
/// implementations, and regenerating it is a protocol change.
final goldenBytes = Uint8List.fromList(const [
  0x70, 0x77, 0x77, 0x77, 0xF1, 0xBB, 0x9B, 0x18, 0x44, 0x53, 0x22, 0x82,
  0xB8, 0xCC, 0xAC, 0x9B, 0x18, 0x52, 0x43, 0x23, 0x02, 0xA9, 0xBD, 0xAD,
  0x9B, 0x08, 0x42, 0x34, 0x24, 0x12, 0xA9, 0xEB, 0xBB, 0x9C, 0x09, 0x32,
  0x45, 0x32, 0x02, 0xA0, 0xCC, 0xCB, 0x9B, 0x09, 0x31, 0x36, 0x43, 0x11,
  0x90, 0xDB, 0xAC, 0xAB, 0x89, 0x41, 0x53, 0x33, 0x13, 0x90, 0xCC, 0xBC,
  0xAB, 0x8A, 0x31, 0x36, 0x34, 0x22, 0x90, 0xCB, 0xBD, 0xBB, 0x8A, 0x21,
  0x45, 0x24, 0x13, 0x91, 0xCA, 0xBC, 0xBC, 0x89, 0x20, 0x63, 0x33, 0x33,
  0x80, 0xDA, 0xBC, 0xAC, 0x9A, 0x20, 0x53, 0x34, 0x23, 0x81, 0xC9, 0xCC,
  0xBB, 0x9A, 0x28, 0x63, 0x43, 0x23, 0x01, 0xBA, 0xCD, 0xBB, 0xAA, 0x10,
  0x63, 0x43, 0x23, 0x01, 0xB8, 0xCD, 0xBB, 0xAB, 0x18, 0x63, 0x43, 0x23,
  0x02, 0xB8, 0xBD, 0xAD, 0x9B, 0x08, 0x42, 0x34,
]);

void main() {
  test('encodes exactly the bytes the firmware encodes', () {
    final state = AdpcmState();
    final out = encodeAdpcmBlock(state, goldenInput());

    expect(out, equals(goldenBytes));
    expect(state.predictor, 949, reason: 'final predictor must match the C side');
    expect(state.stepIndex, 61, reason: 'final step index must match the C side');
  });

  test('encoder and decoder states stay identical', () {
    final pcm = Int16List(1000);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = (8000.0 * math.sin(i * 0.05)).toInt();
    }

    final encoder = AdpcmState();
    final decoder = AdpcmState();

    for (final sample in pcm) {
      final code = encodeAdpcmSample(encoder, sample);
      decodeAdpcmSample(decoder, code);
      expect(decoder.predictor, encoder.predictor);
      expect(decoder.stepIndex, encoder.stepIndex);
    }
  });

  test('a block decodes identically in isolation', () {
    const samplesPerBlock = 348;
    const blocks = 5;

    final pcm = Int16List(samplesPerBlock * blocks);
    for (var i = 0; i < pcm.length; i++) {
      pcm[i] = (6000.0 * math.sin(i * 0.031) + 2000.0 * math.sin(i * 0.17)).toInt();
    }

    final encoder = AdpcmState();
    final headers = <AdpcmState>[];
    final encoded = <Uint8List>[];

    for (var b = 0; b < blocks; b++) {
      headers.add(encoder.copy());
      encoded.add(encodeAdpcmBlock(
          encoder, Int16List.sublistView(pcm, b * samplesPerBlock, (b + 1) * samplesPerBlock)));
    }

    final sequential = <int>[];
    final streaming = AdpcmState();
    for (final block in encoded) {
      sequential.addAll(decodeAdpcmBlock(streaming, block));
    }

    // The last block decoded on its own, as the app does after the device drops
    // the ones before it on congestion.
    final alone = decodeAdpcmBlock(headers[blocks - 1].copy(), encoded[blocks - 1]);
    final base = (blocks - 1) * samplesPerBlock;

    expect(alone, equals(sequential.sublist(base)));
  });
}
```

- [ ] **Step 2: Rodar para ver falhar**

Run: `flutter test test/ble/adpcm_test.dart`
Expected: FALHA — `Error: Couldn't resolve the package 'flycomm/ble/adpcm.dart'`.

- [ ] **Step 3: Escrever a implementação**

Criar `lib/ble/adpcm.dart`:

```dart
import 'dart:typed_data';

/// IMA ADPCM, 4 bits per sample — the Dart side of `flycomm/src/adpcm.cpp`.
///
/// This file is a mirror, not an independent implementation. Every rounding and
/// clamping decision here exists because the C side makes the same one. When the
/// two disagree the symptom is not an error, it is noise on the radio, so the
/// golden fixture test is the thing that actually protects this file.

const List<int> _indexTable = [
  -1, -1, -1, -1, 2, 4, 6, 8, //
  -1, -1, -1, -1, 2, 4, 6, 8,
];

const List<int> _stepTable = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, //
  19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
  130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
  337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
  876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
  2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
  5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
  15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

/// The decoder state a chunk header carries, so that dropping a chunk costs
/// only that chunk instead of corrupting the rest of the burst.
class AdpcmState {
  AdpcmState({this.predictor = 0, this.stepIndex = 0});

  int predictor;
  int stepIndex;

  AdpcmState copy() => AdpcmState(predictor: predictor, stepIndex: stepIndex);
}

int _clampPredictor(int value) {
  if (value > 32767) return 32767;
  if (value < -32768) return -32768;
  return value;
}

int _clampStepIndex(int value) {
  if (value > 88) return 88;
  if (value < 0) return 0;
  return value;
}

/// Shared by both directions, exactly as in the C side: keeping this in one
/// place is what guarantees encoder and decoder cannot drift apart.
int _codeToDelta(int code, int step) {
  var delta = step >> 3;
  if (code & 4 != 0) delta += step;
  if (code & 2 != 0) delta += step >> 1;
  if (code & 1 != 0) delta += step >> 2;
  return delta;
}

int encodeAdpcmSample(AdpcmState state, int sample) {
  final step = _stepTable[state.stepIndex];
  var diff = sample - state.predictor;

  var code = 0;
  if (diff < 0) {
    code = 8;
    diff = -diff;
  }

  var threshold = step;
  if (diff >= threshold) {
    code |= 4;
    diff -= threshold;
  }
  threshold >>= 1;
  if (diff >= threshold) {
    code |= 2;
    diff -= threshold;
  }
  threshold >>= 1;
  if (diff >= threshold) {
    code |= 1;
  }

  final delta = _codeToDelta(code, step);
  state.predictor = _clampPredictor(
      code & 8 != 0 ? state.predictor - delta : state.predictor + delta);
  state.stepIndex = _clampStepIndex(state.stepIndex + _indexTable[code]);
  return code;
}

int decodeAdpcmSample(AdpcmState state, int code) {
  final step = _stepTable[state.stepIndex];
  final delta = _codeToDelta(code, step);
  state.predictor = _clampPredictor(
      code & 8 != 0 ? state.predictor - delta : state.predictor + delta);
  state.stepIndex = _clampStepIndex(state.stepIndex + _indexTable[code]);
  return state.predictor;
}

/// Packs samples two per byte, the even sample in the LOW nibble — the order
/// `adpcm_encode_block` uses. An odd trailing sample is dropped, as it is there.
Uint8List encodeAdpcmBlock(AdpcmState state, Int16List samples) {
  final out = Uint8List(samples.length ~/ 2);
  for (var i = 0; i + 1 < samples.length; i += 2) {
    final low = encodeAdpcmSample(state, samples[i]);
    final high = encodeAdpcmSample(state, samples[i + 1]);
    out[i ~/ 2] = (high << 4) | low;
  }
  return out;
}

Int16List decodeAdpcmBlock(AdpcmState state, Uint8List bytes) {
  final out = Int16List(bytes.length * 2);
  for (var i = 0; i < bytes.length; i++) {
    out[i * 2] = decodeAdpcmSample(state, bytes[i] & 0x0F);
    out[i * 2 + 1] = decodeAdpcmSample(state, (bytes[i] >> 4) & 0x0F);
  }
  return out;
}
```

- [ ] **Step 4: Rodar para ver passar**

Run: `flutter test test/ble/adpcm_test.dart`
Expected: `All tests passed!` — 3 testes.

Se o teste da fixture falhar e os outros dois passarem, o codec está internamente coerente mas divergiu do C. **Não mexa na fixture**: compare `lib/ble/adpcm.dart` com `flycomm/src/adpcm.cpp` linha a linha, porque a diferença está aí.

- [ ] **Step 5: Commit**

```bash
git add lib/ble/adpcm.dart test/ble/adpcm_test.dart
git commit -m "feat: IMA ADPCM in Dart, matching the firmware byte for byte"
```

---

## Task 2: O quadro do protocolo

Espelho de `flycomm/src/chunk.h`. Mesma regra de lá: little-endian escrito campo a campo, nunca confiando em layout de estrutura.

**Files:**
- Create: `lib/ble/chunk.dart`
- Create: `test/ble/chunk_test.dart`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ble/chunk_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/ble/chunk.dart';

void main() {
  // The same byte-for-byte assertion the firmware test makes. A round trip
  // passes even when both sides are wrong in the same way; this does not.
  test('the header has the exact wire layout', () {
    final bytes = writeChunkHeader(const ChunkHeader(
      burstId: 0x2A,
      flags: chunkFlagFirst | chunkFlagContinued,
      sampleOffset: 0x0159,
      predictor: 0x1234,
      stepIndex: 42,
    ));

    expect(
        bytes,
        equals(Uint8List.fromList([
          0x2A, // burstId
          0x05, // flags: first | continued
          0x59, 0x01, // sampleOffset, little endian
          0x34, 0x12, // predictor, little endian
          42, // stepIndex
          0x00, // reserved
        ])));
  });

  test('a negative predictor survives the round trip', () {
    final bytes = writeChunkHeader(const ChunkHeader(
      burstId: 1,
      flags: 0,
      sampleOffset: 40000,
      predictor: -21000,
      stepIndex: 88,
    ));

    final parsed = readChunkHeader(bytes);
    expect(parsed, isNotNull);
    expect(parsed!.predictor, -21000);
    expect(parsed.sampleOffset, 40000);
    expect(parsed.stepIndex, 88);
  });

  test('a truncated packet is rejected, not parsed', () {
    expect(readChunkHeader(Uint8List(chunkHeaderSize - 1)), isNull);
    expect(readChunkHeader(Uint8List(0)), isNull);
  });

  test('a chunk carries its payload after the header', () {
    final payload = Uint8List.fromList([1, 2, 3, 4]);
    final packet = buildChunk(
      const ChunkHeader(
          burstId: 7, flags: chunkFlagLast, sampleOffset: 696, predictor: -5, stepIndex: 12),
      payload,
    );

    expect(packet, hasLength(chunkHeaderSize + payload.length));
    expect(chunkPayload(packet), equals(payload));
    expect(readChunkHeader(packet)!.burstId, 7);
    expect(readChunkHeader(packet)!.flags & chunkFlagLast, isNot(0));
  });
}
```

- [ ] **Step 2: Rodar para ver falhar**

Run: `flutter test test/ble/chunk_test.dart`
Expected: FALHA — `Couldn't resolve the package 'flycomm/ble/chunk.dart'`.

- [ ] **Step 3: Escrever a implementação**

Criar `lib/ble/chunk.dart`:

```dart
import 'dart:typed_data';

/// The 8-byte chunk header — the Dart side of `flycomm/src/chunk.h`.
///
/// Serialised field by field in little endian, for the same reason as there:
/// struct packing and alignment are not something to bet a wire protocol on.

const int chunkHeaderSize = 8;

const int chunkFlagFirst = 0x01;
const int chunkFlagLast = 0x02;
const int chunkFlagContinued = 0x04;

class ChunkHeader {
  const ChunkHeader({
    required this.burstId,
    required this.flags,
    required this.sampleOffset,
    required this.predictor,
    required this.stepIndex,
  });

  /// Rolling 0-255, matching the BURST_START that opened this burst.
  final int burstId;
  final int flags;

  /// Sample index within the burst. It is an offset and not a sequence number
  /// because chunk size varies with the negotiated MTU: a sequence number says
  /// a chunk is missing, an offset says how much audio is missing, and the app
  /// needs the second one to play a gap of the right length.
  final int sampleOffset;

  /// ADPCM decoder state, so a dropped chunk costs only itself.
  final int predictor;
  final int stepIndex;

  bool get isFirst => flags & chunkFlagFirst != 0;
  bool get isLast => flags & chunkFlagLast != 0;
  bool get continuesPreviousBurst => flags & chunkFlagContinued != 0;
}

Uint8List writeChunkHeader(ChunkHeader header) {
  final bytes = Uint8List(chunkHeaderSize);
  final view = ByteData.sublistView(bytes);
  bytes[0] = header.burstId;
  bytes[1] = header.flags;
  view.setUint16(2, header.sampleOffset, Endian.little);
  view.setInt16(4, header.predictor, Endian.little);
  bytes[6] = header.stepIndex;
  bytes[7] = 0;
  return bytes;
}

/// Returns null when the packet is shorter than a header. A truncated write
/// must never be parsed into whatever happened to follow it in the buffer.
ChunkHeader? readChunkHeader(Uint8List bytes) {
  if (bytes.length < chunkHeaderSize) return null;
  final view = ByteData.sublistView(bytes);
  return ChunkHeader(
    burstId: bytes[0],
    flags: bytes[1],
    sampleOffset: view.getUint16(2, Endian.little),
    predictor: view.getInt16(4, Endian.little),
    stepIndex: bytes[6],
  );
}

Uint8List buildChunk(ChunkHeader header, Uint8List payload) {
  final packet = Uint8List(chunkHeaderSize + payload.length)
    ..setAll(0, writeChunkHeader(header))
    ..setAll(chunkHeaderSize, payload);
  return packet;
}

Uint8List chunkPayload(Uint8List packet) =>
    Uint8List.sublistView(packet, chunkHeaderSize);

/// How many ADPCM samples fit in one packet at this MTU. Three bytes go to ATT
/// overhead, eight to the header, and each remaining byte carries two samples.
int samplesPerChunk(int mtu) => (mtu - 3 - chunkHeaderSize) * 2;
```

- [ ] **Step 4: Rodar**

Run: `flutter test test/ble/chunk_test.dart`
Expected: `All tests passed!` — 4 testes.

- [ ] **Step 5: Commit**

```bash
git add lib/ble/chunk.dart test/ble/chunk_test.dart
git commit -m "feat: chunk framing, mirroring the firmware wire layout"
```

---

## Task 3: `control` e `state`

Espelho de `flycomm/src/control.h`. É por estes bytes que o app reserva o canal e descobre se pode transmitir.

**Files:**
- Create: `lib/ble/control.dart`
- Create: `test/ble/control_test.dart`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ble/control_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/ble/control.dart';

void main() {
  test('BURST_START is three bytes: opcode, request id, burst id', () {
    expect(buildBurstStart(requestId: 0x11, burstId: 0x2A),
        equals(Uint8List.fromList([opBurstStart, 0x11, 0x2A])));
  });

  test('ABORT is two bytes', () {
    expect(buildAbort(burstId: 0x2A), equals(Uint8List.fromList([opAbort, 0x2A])));
  });

  test('CONFIG writes the four budgets in little endian', () {
    final bytes = buildConfig(const BridgeConfig(
      segmentMaxMs: 5000,
      pttWatermarkMs: 500,
      hangoverMs: 700,
      energyThreshold: 80,
    ));

    expect(
        bytes,
        equals(Uint8List.fromList([
          opConfig,
          0x88, 0x13, // 5000
          0xF4, 0x01, // 500
          0xBC, 0x02, // 700
          0x50, 0x00, // 80
        ])));
  });

  test('the state payload parses every field', () {
    final bytes = Uint8List.fromList([
      deviceStateTxReserved,
      0x11, // lastRequestId
      verdictAccepted,
      rejectNone,
      0x00, 0x00, // underrunOffset
      0x88, 0x13, // segmentMaxMs  = 5000
      0xF4, 0x01, // pttWatermarkMs = 500
      0xBC, 0x02, // hangoverMs     = 700
      0x50, 0x00, // energyThreshold = 80
    ]);

    final state = readStatePayload(bytes);
    expect(state, isNotNull);
    expect(state!.state, deviceStateTxReserved);
    expect(state.lastRequestId, 0x11);
    expect(state.verdict, verdictAccepted);
    expect(state.underrunOffset, 0);
    expect(state.applied.segmentMaxMs, 5000);
    expect(state.applied.energyThreshold, 80);
    expect(state.accepted, isTrue);
  });

  // Spec 6: the device clamps segment_max_ms to what sample_offset can express,
  // and reports back what it actually applied. The app must read the reply
  // rather than assume its CONFIG took effect verbatim.
  test('the app reads back the clamped config, not what it asked for', () {
    final bytes = Uint8List.fromList([
      deviceStateIdle, 0, verdictNone, rejectNone,
      0x00, 0x00,
      0xFF, 0x1F, // 8191, clamped down from whatever was requested
      0xF4, 0x01, 0xBC, 0x02, 0x50, 0x00,
    ]);

    expect(readStatePayload(bytes)!.applied.segmentMaxMs, 8191);
  });

  test('a truncated state notification is rejected', () {
    expect(readStatePayload(Uint8List(statePayloadSize - 1)), isNull);
  });

  test('a rejection carries the reason the channel was unavailable', () {
    final bytes = Uint8List.fromList([
      deviceStateReceiving, 0x11, verdictRejected, rejectReceiving,
      0x00, 0x00, 0x88, 0x13, 0xF4, 0x01, 0xBC, 0x02, 0x50, 0x00,
    ]);

    final state = readStatePayload(bytes)!;
    expect(state.accepted, isFalse);
    expect(state.rejectReason, rejectReceiving);
  });
}
```

- [ ] **Step 2: Rodar para ver falhar**

Run: `flutter test test/ble/control_test.dart`
Expected: FALHA — `Couldn't resolve the package 'flycomm/ble/control.dart'`.

- [ ] **Step 3: Escrever a implementação**

Criar `lib/ble/control.dart`:

```dart
import 'dart:typed_data';

/// The `control` and `state` wire formats — the Dart side of
/// `flycomm/src/control.h`.
///
/// The shape of the exchange: the app writes BURST_START and waits for the
/// device to answer over `state`. An ATT write response carries no payload, so
/// the verdict cannot ride on it — the request id is what correlates the reply
/// with the request, and the app never has to guess which one it is for.

const int opBurstStart = 0x01;
const int opAbort = 0x02;
const int opConfig = 0x03;

const int deviceStateIdle = 0;
const int deviceStateChannelBusy = 1;
const int deviceStateReceiving = 2;
const int deviceStateTxReserved = 3;
const int deviceStateTransmitting = 4;
const int deviceStateGuard = 5;
const int deviceStateFault = 6;

const int verdictNone = 0;
const int verdictAccepted = 1;
const int verdictRejected = 2;

const int rejectNone = 0;
const int rejectChannelBusy = 1;
const int rejectReceiving = 2;
const int rejectGuard = 3;
const int rejectFault = 4;

const int statePayloadSize = 14;

/// What the device runs on. The app pushes these right after connecting so the
/// numbers stay tunable from the server side (spec 6): baking them into
/// firmware would mean calibrating by cable.
class BridgeConfig {
  const BridgeConfig({
    required this.segmentMaxMs,
    required this.pttWatermarkMs,
    required this.hangoverMs,
    required this.energyThreshold,
  });

  final int segmentMaxMs;
  final int pttWatermarkMs;
  final int hangoverMs;
  final int energyThreshold;
}

class BridgeState {
  const BridgeState({
    required this.state,
    required this.lastRequestId,
    required this.verdict,
    required this.rejectReason,
    required this.underrunOffset,
    required this.applied,
  });

  final int state;
  final int lastRequestId;
  final int verdict;
  final int rejectReason;

  /// Where a transmission stopped when the device ran out of buffered audio.
  /// It tells the app how much of the message actually made it on the air, not
  /// merely that something failed.
  final int underrunOffset;

  /// What the device is really running, after its own clamping.
  final BridgeConfig applied;

  bool get accepted => verdict == verdictAccepted;
  bool get rejected => verdict == verdictRejected;
  bool get canStartBurst => state == deviceStateIdle;
}

Uint8List buildBurstStart({required int requestId, required int burstId}) =>
    Uint8List.fromList([opBurstStart, requestId, burstId]);

Uint8List buildAbort({required int burstId}) =>
    Uint8List.fromList([opAbort, burstId]);

Uint8List buildConfig(BridgeConfig config) {
  final bytes = Uint8List(9);
  final view = ByteData.sublistView(bytes);
  bytes[0] = opConfig;
  view.setUint16(1, config.segmentMaxMs, Endian.little);
  view.setUint16(3, config.pttWatermarkMs, Endian.little);
  view.setUint16(5, config.hangoverMs, Endian.little);
  view.setUint16(7, config.energyThreshold, Endian.little);
  return bytes;
}

/// Returns null for a notification shorter than the payload. These values
/// decide whether the app believes it can transmit, so a short read must not
/// become a confident wrong answer.
BridgeState? readStatePayload(Uint8List bytes) {
  if (bytes.length < statePayloadSize) return null;
  final view = ByteData.sublistView(bytes);
  return BridgeState(
    state: bytes[0],
    lastRequestId: bytes[1],
    verdict: bytes[2],
    rejectReason: bytes[3],
    underrunOffset: view.getUint16(4, Endian.little),
    applied: BridgeConfig(
      segmentMaxMs: view.getUint16(6, Endian.little),
      pttWatermarkMs: view.getUint16(8, Endian.little),
      hangoverMs: view.getUint16(10, Endian.little),
      energyThreshold: view.getUint16(12, Endian.little),
    ),
  );
}
```

- [ ] **Step 4: Rodar**

Run: `flutter test test/ble/control_test.dart`
Expected: `All tests passed!` — 7 testes.

- [ ] **Step 5: Commit**

```bash
git add lib/ble/control.dart test/ble/control_test.dart
git commit -m "feat: control and state wire formats on the app side"
```

---

## Task 4: Reamostragem de 16 kHz para 8 kHz, com filtro

O app grava PCM16 a 16 kHz e o enlace carrega 8 kHz. Jogar fora uma amostra a cada duas parece a coisa óbvia e é um bug: tudo acima de 4 kHz **rebate para dentro da banda de voz** em vez de sumir. Um sibilo de 6 kHz reaparece como um assobio de 2 kHz, bem no meio da fala, e nenhuma quantidade de ajuste no rádio conserta.

O conteúdo acima de 3,4 kHz não faz falta — o VHF corta em ~3 kHz de qualquer forma. O que faz falta é ele não voltar disfarçado.

**Files:**
- Create: `lib/ble/resampler.dart`
- Create: `test/ble/resampler_test.dart`

- [ ] **Step 1: Escrever o teste que falha**

Criar `test/ble/resampler_test.dart`:

```dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/ble/resampler.dart';

Int16List tone(double hz, int samples, {double amplitude = 8000}) {
  final pcm = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    pcm[i] = (amplitude * math.sin(2 * math.pi * hz * i / Decimator.inputRateHz)).toInt();
  }
  return pcm;
}

double rms(Int16List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s.toDouble();
  }
  return math.sqrt(sum / samples.length);
}

void main() {
  test('halves the sample count', () {
    final out = Decimator().add(tone(1000, 1600));
    expect(out, hasLength(800));
  });

  test('a 1 kHz tone passes through with its level intact', () {
    final input = tone(1000, 1600);
    final out = Decimator().add(input);

    // Skip the filter's warm-up, where the delay line is still filling.
    final settled = Int16List.sublistView(out, 64);
    expect(rms(settled), closeTo(rms(input), rms(input) * 0.1));
  });

  // The whole reason this file exists. Without the filter, 6 kHz folds to 2 kHz
  // and lands in the middle of speech.
  test('a 6 kHz tone does not fold back into the voice band', () {
    final input = tone(6000, 1600);
    final out = Decimator().add(input);

    final settled = Int16List.sublistView(out, 64);
    expect(rms(settled), lessThan(rms(input) * 0.05),
        reason: 'aliasing: 6 kHz came through instead of being filtered out');
  });

  // The bug a stateless resampler has: it looks right on one buffer and clicks
  // at every chunk boundary, because the filter's delay line restarts empty.
  test('chunked input gives byte-identical output to one long buffer', () {
    final input = tone(1200, 1600);

    final whole = Decimator().add(input);

    final chunked = <int>[];
    final streaming = Decimator();
    // 37 is odd on purpose: it forces the decimation phase to carry across
    // chunk boundaries instead of resetting to even every time.
    for (var i = 0; i < input.length; i += 37) {
      final end = math.min(i + 37, input.length);
      chunked.addAll(streaming.add(Int16List.sublistView(input, i, end)));
    }

    expect(chunked, equals(whole.toList()));
  });

  test('silence in, silence out', () {
    expect(rms(Decimator().add(Int16List(1600))), 0);
  });
}
```

- [ ] **Step 2: Rodar para ver falhar**

Run: `flutter test test/ble/resampler_test.dart`
Expected: FALHA — `Couldn't resolve the package 'flycomm/ble/resampler.dart'`.

- [ ] **Step 3: Escrever a implementação**

Criar `lib/ble/resampler.dart`:

```dart
import 'dart:math' as math;
import 'dart:typed_data';

/// 16 kHz to 8 kHz, low-passed before decimating.
///
/// Dropping every other sample is the obvious move and it is wrong: everything
/// above 4 kHz does not disappear, it FOLDS DOWN into the voice band. A 6 kHz
/// hiss comes back as a 2 kHz whistle sitting in the middle of speech, and no
/// amount of tuning at the radio end removes it.
///
/// Losing content above 3.4 kHz costs nothing here — VHF cuts around 3 kHz
/// anyway. What matters is that it does not come back wearing a disguise.
///
/// The filter is stateful across calls, and that is the point: the microphone
/// arrives in chunks, and a resampler that restarts its delay line per chunk
/// clicks at every boundary.
class Decimator {
  Decimator({int taps = 31, double cutoffHz = 3400})
      : assert(taps.isOdd, 'an odd tap count keeps the filter symmetric'),
        _taps = _lowPassTaps(taps: taps, cutoffHz: cutoffHz),
        _history = Float64List(taps);

  static const int inputRateHz = 16000;
  static const int outputRateHz = 8000;

  final Float64List _taps;
  final Float64List _history;
  int _write = 0;

  /// 0 or 1. Which input sample produces an output, carried across chunks so a
  /// chunk of odd length does not silently resample the next one out of phase.
  int _phase = 0;

  void reset() {
    _history.fillRange(0, _history.length, 0);
    _write = 0;
    _phase = 0;
  }

  Int16List add(Int16List samples) {
    final out = Int16List((samples.length + 1 - _phase) ~/ 2);
    var produced = 0;

    for (final sample in samples) {
      _history[_write] = sample.toDouble();
      _write = (_write + 1) % _history.length;

      if (_phase == 0) {
        var acc = 0.0;
        // Walks oldest to newest. The taps are symmetric, so their order
        // relative to the history does not matter.
        for (var k = 0; k < _taps.length; k++) {
          acc += _taps[k] * _history[(_write + k) % _history.length];
        }
        out[produced++] = _clampToInt16(acc.round());
      }
      _phase ^= 1;
    }

    return produced == out.length ? out : Int16List.sublistView(out, 0, produced);
  }
}

int _clampToInt16(int value) {
  if (value > 32767) return 32767;
  if (value < -32768) return -32768;
  return value;
}

/// Windowed sinc, Hamming, normalised to unit gain at DC.
///
/// Generated rather than hardcoded: a table of magic constants is a table
/// nobody can check, and this is twenty lines that anyone can read against a
/// textbook.
Float64List _lowPassTaps({required int taps, required double cutoffHz}) {
  final fc = cutoffHz / Decimator.inputRateHz;
  final m = taps - 1;
  final h = Float64List(taps);
  var sum = 0.0;

  for (var i = 0; i < taps; i++) {
    final n = i - m / 2;
    final sinc = n == 0 ? 2 * fc : math.sin(2 * math.pi * fc * n) / (math.pi * n);
    final window = 0.54 - 0.46 * math.cos(2 * math.pi * i / m);
    h[i] = sinc * window;
    sum += h[i];
  }

  for (var i = 0; i < taps; i++) {
    h[i] /= sum;
  }
  return h;
}
```

- [ ] **Step 4: Rodar**

Run: `flutter test test/ble/resampler_test.dart`
Expected: `All tests passed!` — 5 testes.

- [ ] **Step 5: Commit**

```bash
git add lib/ble/resampler.dart test/ble/resampler_test.dart
git commit -m "feat: anti-aliased 16k to 8k decimation, stateful across chunks"
```

---

## Task 5: A conexão com o dispositivo

Daqui em diante nada é testável sem hardware. O que dá para garantir é que analisa e compila, e que a API usada é a do pacote realmente instalado.

**Files:**
- Create: `lib/ble/bridge_link.dart`

- [ ] **Step 1: Conferir a API do pacote instalado**

A API do `flutter_blue_plus` mudou entre versões maiores. Antes de escrever, confirme os nomes abaixo no pacote que a Task 0 resolveu:

```bash
grep -rn "Stream<List<ScanResult>> get onScanResults\|Future<int> requestMtu\|Stream<List<int>> get onValueReceived\|Future<void> write(" ~/.pub-cache/hosted/pub.dev/flutter_blue_plus-*/lib/src/*.dart | head
```

Se algum nome divergir, ajuste o código do Step 2 para o do pacote — o `flutter analyze` da Task 7 é a rede de segurança, mas conferir aqui poupa a ida e volta.

- [ ] **Step 2: Escrever a implementação**

Criar `lib/ble/bridge_link.dart`:

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'control.dart';

/// The BLE central side of the bridge — the counterpart of `flycomm/src/link.cpp`.
///
/// These UUIDs are the contract with the firmware. Changing one here orphans
/// every device already flashed.
const String serviceUuid = '6f9a0001-4b3c-4f5e-9a2d-1c7e5b8d3f01';
const String controlUuid = '6f9a0002-4b3c-4f5e-9a2d-1c7e5b8d3f01';
const String txAudioUuid = '6f9a0003-4b3c-4f5e-9a2d-1c7e5b8d3f01';
const String rxAudioUuid = '6f9a0004-4b3c-4f5e-9a2d-1c7e5b8d3f01';
const String stateUuid = '6f9a0005-4b3c-4f5e-9a2d-1c7e5b8d3f01';

class BridgeLink {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _control;
  BluetoothCharacteristic? _txAudio;
  BluetoothCharacteristic? _rxAudio;
  BluetoothCharacteristic? _state;

  final _states = StreamController<BridgeState>.broadcast();
  final _audio = StreamController<Uint8List>.broadcast();
  StreamSubscription<List<int>>? _stateSub;
  StreamSubscription<List<int>>? _audioSub;

  /// Every `state` notification the device sends: its current state, and the
  /// verdict on the last reservation.
  Stream<BridgeState> get states => _states.stream;

  /// Raw `rx_audio` chunks, header included. Parsing is the caller's job —
  /// this class moves bytes and does not interpret them.
  Stream<Uint8List> get audio => _audio.stream;

  bool get connected => _device != null;

  /// 23 until the device and the phone agree on something larger. iOS settles
  /// at 185 and Android goes higher; the chunk size follows from whichever it
  /// turns out to be, which is why it is read and not assumed.
  int get mtu => _device?.mtuNow ?? 23;

  /// Scans for a device advertising our service. Returns null on timeout.
  ///
  /// The deadline is an explicit timer rather than startScan's own `timeout`
  /// because whether startScan returns immediately or when the scan window
  /// closes has differed between versions of the package. Owning the deadline
  /// here means this method behaves the same either way.
  Future<BluetoothDevice?> findBridge({Duration timeout = const Duration(seconds: 10)}) async {
    final completer = Completer<BluetoothDevice?>();

    final sub = FlutterBluePlus.onScanResults.listen((results) {
      if (results.isNotEmpty && !completer.isCompleted) {
        completer.complete(results.first.device);
      }
    });

    final deadline = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      await FlutterBluePlus.startScan(withServices: [Guid(serviceUuid)]);
      return await completer.future;
    } finally {
      deadline.cancel();
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    await device.connect();
    _device = device;

    // Android honours this; iOS negotiates on its own and ignores the request.
    try {
      await device.requestMtu(247);
    } catch (_) {
      // Not fatal: a small MTU means small chunks, not a broken link.
    }

    final services = await device.discoverServices();
    final service = services.firstWhere(
      (s) => s.uuid == Guid(serviceUuid),
      orElse: () => throw StateError('device does not expose the bridge service'),
    );

    BluetoothCharacteristic pick(String uuid) => service.characteristics.firstWhere(
          (c) => c.uuid == Guid(uuid),
          orElse: () => throw StateError('missing characteristic $uuid'),
        );

    _control = pick(controlUuid);
    _txAudio = pick(txAudioUuid);
    _rxAudio = pick(rxAudioUuid);
    _state = pick(stateUuid);

    await _state!.setNotifyValue(true);
    _stateSub = _state!.onValueReceived.listen((bytes) {
      final parsed = readStatePayload(Uint8List.fromList(bytes));
      if (parsed != null) _states.add(parsed);
    });

    await _rxAudio!.setNotifyValue(true);
    _audioSub = _rxAudio!.onValueReceived.listen((bytes) {
      _audio.add(Uint8List.fromList(bytes));
    });
  }

  Future<void> disconnect() async {
    await _stateSub?.cancel();
    await _audioSub?.cancel();
    await _device?.disconnect();
    _device = null;
    _control = _txAudio = _rxAudio = _state = null;
  }

  /// Pushes the budgets to the device. Call right after connecting: until it
  /// lands, the device runs on its own defaults.
  Future<void> pushConfig(BridgeConfig config) async {
    await _control!.write(buildConfig(config), withoutResponse: false);
  }

  /// Reserves the channel and waits for the device to answer.
  ///
  /// The verdict comes over `state`, not as the write response — ATT write
  /// responses carry no payload. The request id is what ties the answer to this
  /// request, so a stale notification from an earlier attempt cannot be
  /// mistaken for this one's.
  Future<BridgeState?> requestBurst({
    required int requestId,
    required int burstId,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final answer = states
        .firstWhere((s) => s.lastRequestId == requestId && s.verdict != verdictNone)
        .timeout(timeout);

    await _control!.write(buildBurstStart(requestId: requestId, burstId: burstId),
        withoutResponse: false);

    try {
      return await answer;
    } on TimeoutException {
      return null;
    }
  }

  Future<void> abortBurst(int burstId) async {
    await _control!.write(buildAbort(burstId: burstId), withoutResponse: false);
  }

  /// One audio chunk, without response. There is no ACK by design: audio wants
  /// throughput, and the ordering guarantee comes from the link layer below.
  Future<void> sendAudioChunk(Uint8List packet) async {
    await _txAudio!.write(packet, withoutResponse: true);
  }

  Future<void> dispose() async {
    await disconnect();
    await _states.close();
    await _audio.close();
  }
}
```

- [ ] **Step 3: Analisar**

Run: `flutter analyze lib/ble/`
Expected: `No issues found!`

Erro de nome de método aqui é o esperado se a versão resolvida do pacote for diferente da que este plano assumiu — conserte contra a API real, não contorne.

- [ ] **Step 4: Commit**

```bash
git add lib/ble/bridge_link.dart
git commit -m "feat: BLE central connection to the bridge device"
```

---

## Task 6: A bancada de vazão

Isto é o que fecha o portão. O firmware já mede o sentido notify sozinho; o que falta é quem escreva rápido no sentido inverso, e um lugar para ler os dois números.

**Files:**
- Create: `lib/ble/bench.dart`
- Create: `lib/ui/ble_bench_screen.dart`
- Modify: `lib/ui/settings_screen.dart`

- [ ] **Step 1: Escrever o driver**

Criar `lib/ble/bench.dart`:

```dart
import 'dart:typed_data';

import 'adpcm.dart';
import 'bridge_link.dart';
import 'chunk.dart';

/// Measures what the link sustains in the write direction — the number the
/// firmware cannot produce on its own, because nothing on the device end can
/// write to itself.
///
/// Method mirrors `flycomm/bench/throughput_main.cpp`: push a large fixed
/// amount rather than timing individual writes. Once far more bytes than any
/// queue can hold have gone through, elapsed time reflects the rate the link
/// drains at instead of how the stack buffers.
class WriteThroughputBench {
  WriteThroughputBench(this.link);

  final BridgeLink link;

  static const int totalBytes = 200000;

  /// ADPCM at 8 kHz costs this much. Everything else is measured against it.
  static const int requiredBytesPerSecond = 4000;

  /// Below this the design is revisited before anything is built on top.
  static const int gateBytesPerSecond = 6000;

  Future<BenchResult> run({void Function(int sent)? onProgress}) async {
    final samples = samplesPerChunk(link.mtu);
    final payloadBytes = samples ~/ 2;

    // Real ADPCM rather than a constant: a codec that compresses a flat pattern
    // into something unrepresentative would flatter the measurement.
    final pcm = Int16List(samples);
    for (var i = 0; i < samples; i++) {
      pcm[i] = ((i * 137) % 16000) - 8000;
    }

    var sent = 0;
    var offset = 0;
    final stopwatch = Stopwatch()..start();

    while (sent < totalBytes) {
      final state = AdpcmState();
      final payload = encodeAdpcmBlock(state, pcm);
      final packet = buildChunk(
        ChunkHeader(
          burstId: 1,
          flags: offset == 0 ? chunkFlagFirst : 0,
          sampleOffset: offset % 65536,
          predictor: 0,
          stepIndex: 0,
        ),
        payload,
      );

      await link.sendAudioChunk(packet);
      sent += packet.length;
      offset += samples;
      onProgress?.call(sent);
    }

    stopwatch.stop();
    return BenchResult(
      bytes: sent,
      elapsed: stopwatch.elapsed,
      mtu: link.mtu,
      packetBytes: chunkHeaderSize + payloadBytes,
    );
  }
}

class BenchResult {
  const BenchResult({
    required this.bytes,
    required this.elapsed,
    required this.mtu,
    required this.packetBytes,
  });

  final int bytes;
  final Duration elapsed;
  final int mtu;
  final int packetBytes;

  int get bytesPerSecond =>
      elapsed.inMilliseconds == 0 ? 0 : (bytes * 1000) ~/ elapsed.inMilliseconds;

  bool get clearsGate => bytesPerSecond >= WriteThroughputBench.gateBytesPerSecond;
  bool get meetsMinimum => bytesPerSecond >= WriteThroughputBench.requiredBytesPerSecond;
}
```

- [ ] **Step 2: Escrever a tela**

Criar `lib/ui/ble_bench_screen.dart`:

```dart
import 'package:flutter/material.dart';

import '../ble/bench.dart';
import '../ble/bridge_link.dart';
import '../ble/chunk.dart';
import '../ble/control.dart';

/// Bancada da Fase 1: conecta no dispositivo, empurra a config, faz o
/// handshake e mede a vazão de escrita. Não toca na sala.
class BleBenchScreen extends StatefulWidget {
  const BleBenchScreen({super.key});

  @override
  State<BleBenchScreen> createState() => _BleBenchScreenState();
}

class _BleBenchScreenState extends State<BleBenchScreen> {
  final _link = BridgeLink();
  final _log = <String>[];
  bool _busy = false;
  BridgeState? _lastState;
  BenchResult? _result;

  void _say(String line) => setState(() => _log.insert(0, line));

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _guard(String what, Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } catch (error) {
      _say('$what falhou: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _guard('Conexão', () async {
        _say('Procurando o dispositivo...');
        final device = await _link.findBridge();
        if (device == null) {
          _say('Nenhum dispositivo encontrado.');
          return;
        }
        await _link.connect(device);
        _link.states.listen((s) => setState(() => _lastState = s));
        _say('Conectado. MTU ${_link.mtu}, '
            '${samplesPerChunkLabel(_link.mtu)}.');
      });

  Future<void> _pushConfig() => _guard('CONFIG', () async {
        await _link.pushConfig(const BridgeConfig(
          segmentMaxMs: 5000,
          pttWatermarkMs: 500,
          hangoverMs: 700,
          energyThreshold: 80,
        ));
        _say('CONFIG enviada.');
      });

  Future<void> _handshake() => _guard('Handshake', () async {
        final answer = await _link.requestBurst(requestId: 0x11, burstId: 0x2A);
        if (answer == null) {
          _say('Sem veredito dentro do prazo.');
          return;
        }
        _say(answer.accepted
            ? 'Reserva aceita.'
            : 'Reserva recusada, motivo ${answer.rejectReason}.');
        await _link.abortBurst(0x2A);
      });

  Future<void> _bench() => _guard('Medição', () async {
        _say('Medindo o sentido de escrita...');
        final result = await WriteThroughputBench(_link).run();
        setState(() => _result = result);
        _say('${result.bytesPerSecond} B/s '
            '(MTU ${result.mtu}, pacote ${result.packetBytes} B)');
      });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Bancada BLE')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Fase 1 — ponte', style: text.labelLarge),
          const SizedBox(height: 4),
          Text(
            'Mede o que o enlace aguenta antes de o áudio depender dele. '
            'O ADPCM a 8 kHz exige ${WriteThroughputBench.requiredBytesPerSecond} B/s; '
            'abaixo de ${WriteThroughputBench.gateBytesPerSecond} B/s o desenho é revisto.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(
              onPressed: _busy || _link.connected ? null : _connect,
              child: const Text('Conectar'),
            ),
            OutlinedButton(
              onPressed: _busy || !_link.connected ? null : _pushConfig,
              child: const Text('Enviar CONFIG'),
            ),
            OutlinedButton(
              onPressed: _busy || !_link.connected ? null : _handshake,
              child: const Text('Handshake'),
            ),
            FilledButton.tonal(
              onPressed: _busy || !_link.connected ? null : _bench,
              child: const Text('Medir vazão'),
            ),
          ]),
          if (_result != null) ...[
            const SizedBox(height: 20),
            Text('${_result!.bytesPerSecond} B/s', style: text.headlineMedium),
            Text(
              _result!.clearsGate
                  ? 'Passa o portão.'
                  : _result!.meetsMinimum
                      ? 'Funciona, sem margem — revisar antes do Marco 7.'
                      : 'Abaixo do mínimo. O desenho não se sustenta assim.',
              style: text.bodyMedium,
            ),
          ],
          if (_lastState != null) ...[
            const SizedBox(height: 20),
            Text('Estado do dispositivo', style: text.labelLarge),
            Text('state=${_lastState!.state} '
                'segment_max=${_lastState!.applied.segmentMaxMs} ms '
                'watermark=${_lastState!.applied.pttWatermarkMs} ms'),
          ],
          const SizedBox(height: 20),
          Text('Log', style: text.labelLarge),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: text.bodySmall),
            ),
        ],
      ),
    );
  }
}

String samplesPerChunkLabel(int mtu) {
  final samples = samplesPerChunk(mtu);
  return '$samples amostras por pacote (~${(samples * 1000 / 8000).round()} ms)';
}
```

- [ ] **Step 3: Ligar na tela de configuração**

Em `lib/ui/settings_screen.dart`, adicionar ao topo, junto com os outros imports:

```dart
import 'ble_bench_screen.dart';
```

E logo depois do `OutlinedButton.icon` de "Comandos de mídia recebidos", antes do `],` que fecha o `children`, acrescentar:

```dart
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BleBenchScreen()),
            ),
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Bancada BLE'),
          ),
```

Fica junto do log de comandos de mídia porque é a mesma natureza: diagnóstico, não função de voo.

- [ ] **Step 4: Analisar**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/ble/bench.dart lib/ui/ble_bench_screen.dart lib/ui/settings_screen.dart
git commit -m "feat: BLE bench screen that measures the write direction"
```

---

## Task 7: Verificação

**Files:** nenhum

- [ ] **Step 1: A suíte inteira**

Run: `flutter test`
Expected: tudo verde, incluindo as suítes que já existiam. **19 testes novos** em `test/ble/` (3 adpcm + 4 chunk + 7 control + 5 resampler).

- [ ] **Step 2: Análise estática**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Compilar de verdade nos dois sistemas**

```bash
flutter build apk --debug
flutter build ios --debug --no-codesign
```

Expected: os dois terminam sem erro. É aqui que uma permissão mal escrita ou um plugin mal configurado aparece — `flutter analyze` não monta o app.

- [ ] **Step 4: Commit se algo mudou**

```bash
git add -A && git commit -m "fix: whatever the full build surfaced"
```

---

## O que este plano NÃO entrega, e por quê

- **A ponte ligada na sala.** Sem retransmissão de fala para o ar, sem `rx_audio` alimentando a FIFO de reprodução, sem eleição. É o Marco 7, e ele depende do número que a Task 6 produz.
- **PTT do piloto saindo no rádio.** Mesmo motivo.
- **Reconexão em segundo plano no iOS.** Precisa de `bluetooth-central` nos `UIBackgroundModes` mais restauração de estado do `CBCentralManager`. A fatia antecipada da Fase 4 (§7.1 da spec da Fase 2) cobriu áudio, não BLE.

## Depois da Task 6: o portão

Com o número na mão, a decisão é a mesma dos dois lados, e está escrita na §3.2 da spec:

| Medido | O que fazer |
|---|---|
| ≥ 6000 B/s nos dois sistemas | O desenho se sustenta. Escrever o plano do Marco 7. |
| 4000 a 6000 B/s | Funciona sem margem. Antes do Marco 7: intervalo de conexão menor, NimBLE no firmware, pacote maior no Android. |
| < 4000 B/s | Não se sustenta. Revisitar pacote, codec, ou o streaming ao vivo da §4.3 — antes de construir em cima. |

Registrar o resultado na §3.2 da spec **no repo `flycomm`**, nunca na cópia daqui, e então `cp` para os dois repos.
