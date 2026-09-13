import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

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
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        // Eco e ruído ficam ligados: o piloto está num ambiente barulhento e
        // meio-duplex já garante que nada toca enquanto ele fala.
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
