import 'dart:async';

import '../audio/playback_queue.dart';
import '../audio/player.dart';
import '../audio/recorder.dart';
import '../history/audio_store.dart';
import '../history/database.dart';
import '../history/history_repository.dart';
import 'budgets.dart';
import 'catchup_repository.dart';
import 'message_api.dart';
import 'message_uploader.dart';
import 'models.dart';
import 'reverb_client.dart';
import 'server_clock.dart';

/// Uma sessão de sala aberta: o WebSocket, a fila, o gravador e o histórico
/// amarrados. Uma instância por sala aberta; `dispose` ao sair.
class RoomSession {
  RoomSession({
    required this.room,
    required this.budgets,
    required this.clock,
    required this.reverb,
    required this.catchup,
    required this.messageApi,
    required this.history,
    required this.audioStore,
    required this.uploader,
    required this.recorder,
    required this.player,
  }) {
    _queue = PlaybackQueue(
      clock: clock,
      budgets: budgets,
      play: _playFromStore,
    );

    // Item que passou do prazo sai da fila sem tocar e vira "atrasada" no
    // histórico — ouvível por toque, nunca automaticamente.
    _subscriptions.add(_queue.dropped.listen((item) async {
      await history.markLate(item.messageId);
    }));

    _subscriptions.add(reverb.messages.listen(ingest));

    _subscriptions.add(reverb.roomUpdates.listen((updated) {
      _room = updated;
      _roomChanges.add(updated);
    }));

    _subscriptions.add(recorder.segments.listen(_publishSegment));

    _room = room;
  }

  final Room room;
  final Budgets budgets;
  final ServerClock clock;
  final ReverbClient reverb;
  final CatchupRepository catchup;
  final MessageApi messageApi;
  final HistoryRepository history;
  final AudioStore audioStore;

  /// Vem de fora e não é descartado aqui: a insistência dura minutos e precisa
  /// sobreviver ao piloto sair da tela da sala. Ver [MessageUploader].
  final MessageUploader uploader;

  final PttRecorder recorder;
  final SegmentPlayer player;

  late final PlaybackQueue _queue;

  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _roomChanges = StreamController<Room>.broadcast();
  final _gaps = StreamController<DateTime>.broadcast();

  late Room _room;

  Room get current => _room;
  Stream<Room> get roomChanges => _roomChanges.stream;

  /// Emite quando o catch-up descobriu um buraco no histórico.
  Stream<DateTime> get gaps => _gaps.stream;

  Stream<List<LocalMessage>> get messages => history.watchRoom(room.id);
  Stream<RoomPresence> get presence => reverb.presence;
  Stream<ReverbConnection> get connectionState => reverb.connectionState;

  Future<void> open() async {
    // Cada (re)assinatura roda o catch-up de novo. É isto que cobre o caso para
    // o qual a janela de 60 s foi desenhada: o WebSocket cai e volta oito
    // segundos depois, e o que passou nesse intervalo precisa entrar.
    _subscriptions.add(reverb.connectionState.listen((state) {
      if (state == ReverbConnection.connected) syncCatchup();
    }));

    await reverb.connect(room);
    await syncCatchup();
  }

  /// Chamado na entrada e a cada reconexão do WebSocket.
  Future<void> syncCatchup() async {
    final since = await history.lastSeenAt(room.id);
    final result = await catchup.fetch(room.id, since: since);

    if (result.hasGapSince(since)) _gaps.add(result.windowStart);

    for (final message in result.messages) {
      await ingest(message);
    }
  }

  /// O caminho único de entrada: o evento, a resposta do upload e o catch-up
  /// chegam aqui, porque são a mesma mensagem.
  Future<void> ingest(RoomMessage message) async {
    if (await history.exists(message.id)) return;

    // A idade é a DA FALA, não a da chegada (spec 2.1): com entrega atrasada
    // permitida, `created_at` mede o tempo errado — uma fala de três minutos
    // atrás recebida agora tem `created_at` de agora e tocaria como se fosse
    // nova. Origem `radio` não tem `captured_at`, e aí a chegada é o que há.
    final spokenAt = message.capturedAt ?? message.createdAt;

    // O excedente da janela de catch-up não toca, mas preenche o histórico:
    // sem isso haveria um buraco sem nenhum indício de que algo aconteceu ali.
    final tooOld = clock.ageOf(spokenAt) > budgets.playbackDeadline;

    await history.recordIncoming(
      message,
      tooOld ? MessageState.late : MessageState.received,
    );

    try {
      final bytes = await messageApi.download(message.audioUrl);
      await audioStore.write(message.id, bytes);
      await history.setAudioPath(message.id, audioStore.pathFor(message.id));
    } catch (_) {
      // O blob expirou ou a rede caiu. A linha fica no histórico sem áudio:
      // o piloto vê que algo foi dito e que não dá para ouvir.
      await history.markLate(message.id);
      return;
    }

    if (!tooOld) {
      _queue.enqueue(
        QueuedItem(messageId: message.id, spokenAt: spokenAt),
      );
    }
  }

  Future<void> _playFromStore(QueuedItem item) async {
    if (!audioStore.has(item.messageId)) return;
    await player.play(audioStore.pathFor(item.messageId));
    await history.markPlayed(item.messageId);
  }

  /// Reprodução por toque, do histórico. Entra na mesma fila e respeita o
  /// meio-duplex, mas ignora o prazo: o piloto pediu para ouvir.
  /// Devolve `null` quando tocou, ou a razão de não ter tocado.
  ///
  /// Devolver a razão em vez de engolir o erro é deliberado: uma mensagem que
  /// não toca e não explica nada é indistinguível de um app quebrado, e o
  /// piloto precisa saber se o áudio sumiu ou se o aparelho falhou.
  Future<String?> playFromHistory(String messageId) async {
    if (!audioStore.has(messageId)) {
      return 'O áudio não está no aparelho: ele venceu no servidor antes de '
          'dar tempo de baixar.';
    }

    try {
      await player.play(audioStore.pathFor(messageId));
      return null;
    } catch (error) {
      return 'Não deu para tocar: $error';
    }
  }

  /// Meio-duplex: enquanto o PTT está acionado, nada toca.
  Future<void> pressPtt() async {
    _queue.pttHeld = true;
    await player.interrupt();
    await recorder.start();
  }

  Future<void> releasePtt() async {
    await recorder.stop();
    _queue.pttHeld = false;
  }

  Future<void> _publishSegment(CapturedSegment segment) async {
    final path = await audioStore.write(segment.id, segment.wavBytes);

    await history.recordOutgoing(
      id: segment.id,
      roomId: room.id,
      burstId: segment.burstId,
      index: segment.index,
      durationMs: segment.durationMs,
      format: MessageApi.format,
      capturedAt: segment.capturedAt,
      audioPath: path,
    );

    await uploader.upload(OutgoingSegment(
      id: segment.id,
      roomId: room.id,
      burstId: segment.burstId,
      index: segment.index,
      durationMs: segment.durationMs,
      capturedAt: segment.capturedAt,
      wavBytes: segment.wavBytes,
    ));
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _queue.dispose();
    await reverb.dispose();
    await recorder.dispose();
    await player.dispose();
    await _roomChanges.close();
    await _gaps.close();
  }
}
