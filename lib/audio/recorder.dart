import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../trace.dart';
import 'segmenter.dart';
import 'wav.dart';

/// Um segmento fechado, pronto para subir.
class CapturedSegment {
  const CapturedSegment({
    required this.id,
    required this.burstId,
    required this.index,
    required this.durationMs,
    required this.capturedAt,
    required this.wavBytes,
  });

  final String id;
  final String burstId;
  final int index;
  final int durationMs;
  final DateTime capturedAt;
  final Uint8List wavBytes;
}

/// Captura PCM 16 bits a 16 kHz em stream e a corta em segmentos.
///
/// Grava PCM uma vez: a Fase 3 deriva ADPCM 8 kHz deste mesmo PCM, e gravar
/// direto em formato comprimido obrigaria a reescrever a camada de áudio.
class PttRecorder {
  PttRecorder({
    required this.segmentMax,
    required DateTime Function() serverNow,
    AudioRecorder? recorder,
  })  : _serverNow = serverNow,
        _recorder = recorder ?? AudioRecorder();

  final Duration segmentMax;
  final DateTime Function() _serverNow;
  final AudioRecorder _recorder;
  final _uuid = const Uuid();

  final _segments = StreamController<CapturedSegment>.broadcast();

  /// Os segmentos fechados, na ordem. Quem escuta sobe cada um assim que
  /// chega — a fala de 12 s já está subindo enquanto o piloto ainda fala.
  Stream<CapturedSegment> get segments => _segments.stream;

  StreamSubscription<Uint8List>? _subscription;
  PcmSegmenter? _segmenter;
  String? _burstId;
  int _index = 0;
  bool _recording = false;

  bool get isRecording => _recording;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// O piloto segurou o PTT.
  Future<void> start() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('sem permissão de microfone');
    }

    _burstId = _uuid.v4();
    _index = 0;
    _segmenter = PcmSegmenter(segmentMax: segmentMax);
    _recording = true;

    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,

        // A fonte de áudio. `camcorder` no Android não é escolha estética:
        // é a única das seis testadas que captou voz no aparelho de bancada.
        //
        // Varredura num Galaxy A12 (MediaTek MT6765), seis gravações de 3 s
        // seguidas, mesma voz, mesma distância, num app isolado que só tinha
        // o pacote `record` — sem `audio_session`, sem player, sem flycomm:
        //
        //   fonte              taxa     pico    modulação   veredito
        //   defaultSource      16 kHz    388      0.257     ruído
        //   defaultSource      48 kHz    129      0.276     ruído
        //   mic              44,1 kHz    118      0.273     ruído
        //   unprocessed        48 kHz      6      0.040     mudo
        //   voiceRecognition   48 kHz     71      0.120     ruído
        //   camcorder          48 kHz  32767      0.887     FALA
        //
        // Não é diferença de grau, é a diferença entre ter voz e não ter. E o
        // padrão que o `camcorder` quebra explica o resto: todas as fontes que
        // falharam usam o microfone **principal**, e a que funcionou usa o
        // **secundário**, o de perto da câmera. O microfone principal deste
        // aparelho não entrega áudio.
        //
        // Por isso nenhum ajuste anterior adiantou. Foram testados e todos
        // falharam pelo mesmo motivo — mexiam no ganho de um sinal que não
        // existia: `autoGain` (+2 dB e mais chiado), `voiceCommunication`
        // (piorou para 146), captura a 48 kHz (piorou para 112), e ganho
        // digital nosso, que amplificou ruído. A subtração espectral não
        // recuperou nenhuma palavra — porque não havia palavra ali.
        //
        // ATENÇÃO ANTES DE GENERALIZAR: isto é uma medição em **um** aparelho,
        // que muito provavelmente tem o microfone principal defeituoso ou
        // obstruído. `camcorder` usa um microfone mais distante da boca e
        // afinado para captação ampla — não é a escolha certa para um rádio
        // num aparelho são. Antes de isto virar padrão de verdade, precisa
        // rodar a mesma varredura num segundo Android. O caminho honesto a
        // prazo é escolher a fonte medindo, não fixando: gravar, olhar o pico,
        // e cair para outra fonte se vier silêncio.
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.camcorder,
        ),
      ),
    );

    _subscription = stream.listen(
      (chunk) {
        for (final pcm in _segmenter!.add(chunk)) {
          _emit(pcm);
        }
      },
      onError: (Object error, StackTrace stack) =>
          _segments.addError(error, stack),
    );
  }

  /// O piloto soltou o PTT: fecha o último segmento, que é parcial.
  Future<void> stop() async {
    if (!_recording) return;
    _recording = false;

    await _subscription?.cancel();
    _subscription = null;
    await _recorder.stop();

    final tail = _segmenter?.close();
    if (tail != null && tail.isNotEmpty) _emit(tail);

    _segmenter = null;
    _burstId = null;
  }

  void _emit(Uint8List pcm) {
    // O pico é a única coisa que distingue um segmento com fala de um segmento
    // mudo: duração e tamanho saem da contagem de bytes e são idênticos nos
    // dois casos. Sem isto, uma captura que não captou nada sobe com metadado
    // impecável e o defeito só aparece no ouvido de outra pessoa.
    trace('segmento $_index: ${durationMsOfPcm(pcm.length)}ms '
        'pico=${peakAmplitudeOfPcm(pcm)}/32768');

    _segments.add(CapturedSegment(
      id: _uuid.v4(),
      burstId: _burstId!,
      index: _index++,
      durationMs: durationMsOfPcm(pcm.length),
      // O carimbo do cliente, só para o histórico — a autoridade de frescor é
      // o created_at que o servidor emite.
      capturedAt: _serverNow(),
      wavBytes: wrapPcmInWav(pcm),
    ));
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
    await _segments.close();
  }
}
