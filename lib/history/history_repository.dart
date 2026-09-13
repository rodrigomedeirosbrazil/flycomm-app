import 'package:drift/drift.dart';

import '../room/models.dart';
import 'database.dart';

class HistoryRepository {
  HistoryRepository(this.db);

  final HistoryDatabase db;

  Future<void> recordOutgoing({
    required String id,
    required int roomId,
    required String burstId,
    required int index,
    required int durationMs,
    required String format,
    required DateTime capturedAt,
    required String audioPath,
  }) =>
      db.into(db.localMessages).insertOnConflictUpdate(
            LocalMessagesCompanion.insert(
              id: id,
              roomId: roomId,
              burstId: burstId,
              segmentIndex: index,
              durationMs: durationMs,
              origin: 'app',
              format: format,
              capturedAt: Value(capturedAt),
              direction: MessageDirection.outgoing,
              state: MessageState.recorded,
              audioPath: Value(audioPath),
              recordedAt: capturedAt,
            ),
          );

  Future<void> recordIncoming(RoomMessage message, MessageState state) =>
      db.into(db.localMessages).insertOnConflictUpdate(
            LocalMessagesCompanion.insert(
              id: message.id,
              roomId: message.roomId,
              burstId: message.burstId,
              segmentIndex: message.index,
              authorId: Value(message.authorId),
              authorName: Value(message.authorName),
              durationMs: message.durationMs,
              origin: message.origin,
              format: message.format,
              sizeBytes: Value(message.sizeBytes),
              capturedAt: Value(message.capturedAt),
              createdAt: Value(message.createdAt.toUtc()),
              direction: MessageDirection.incoming,
              state: state,
              // A posição é a da fala, não a da chegada: uma mensagem gravada
              // às 12:00 e recebida às 12:03 pertence às 12:00. Origem `radio`
              // não tem capturedAt, e aí a chegada é o melhor que existe.
              recordedAt: (message.capturedAt ?? message.createdAt).toUtc(),
            ),
          );

  Future<void> _setState(String id, MessageState state) =>
      (db.update(db.localMessages)..where((t) => t.id.equals(id)))
          .write(LocalMessagesCompanion(state: Value(state)));

  Future<void> markSending(String id) => _setState(id, MessageState.sending);

  Future<void> markUndelivered(String id) =>
      _setState(id, MessageState.undelivered);

  /// O servidor aceitou: agora a mensagem tem `created_at`, que é quando ela
  /// chegou, e `size_bytes`, que o servidor mediu.
  ///
  /// [wasLate] distingue os dois desfechos de sucesso. Ele não é derivado aqui
  /// porque depende do `playbackDeadline`, e quem tem os orçamentos na mão é o
  /// uploader.
  Future<void> markDelivered(
    String id,
    RoomMessage accepted, {
    bool wasLate = false,
  }) =>
      (db.update(db.localMessages)..where((t) => t.id.equals(id))).write(
        LocalMessagesCompanion(
          state: Value(
            wasLate ? MessageState.deliveredLate : MessageState.delivered,
          ),
          createdAt: Value(accepted.createdAt),
          sizeBytes: Value(accepted.sizeBytes),
          authorId: Value(accepted.authorId),
          authorName: Value(accepted.authorName),
        ),
      );

  Future<void> setAudioPath(String id, String path) =>
      (db.update(db.localMessages)..where((t) => t.id.equals(id)))
          .write(LocalMessagesCompanion(audioPath: Value(path)));

  Future<void> markPlayed(String id) => _setState(id, MessageState.received);

  /// Saiu da fila sem tocar, ou o áudio não pôde ser baixado. Fica ouvível por
  /// toque, nunca automaticamente.
  Future<void> markLate(String id) => _setState(id, MessageState.late);

  Future<LocalMessage?> byId(String id) =>
      (db.select(db.localMessages)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  Future<bool> exists(String id) async => (await byId(id)) != null;

  Future<int> countForRoom(int roomId) async =>
      (await forRoom(roomId)).length;

  Future<List<LocalMessage>> forRoom(int roomId) =>
      (db.select(db.localMessages)
            ..where((t) => t.roomId.equals(roomId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.recordedAt),
              (t) => OrderingTerm(expression: t.burstId),
              (t) => OrderingTerm(expression: t.segmentIndex),
            ]))
          .get();

  Stream<List<LocalMessage>> watchRoom(int roomId) =>
      (db.select(db.localMessages)
            ..where((t) => t.roomId.equals(roomId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.recordedAt, mode: OrderingMode.desc),
              (t) => OrderingTerm(expression: t.segmentIndex, mode: OrderingMode.desc),
            ]))
          .watch();

  /// O `since` do catch-up: o createdAt da última mensagem que vimos — um
  /// carimbo que o próprio servidor emitiu, nunca o relógio do celular.
  Future<DateTime?> lastSeenAt(int roomId) async {
    final query = db.select(db.localMessages)
      ..where((t) => t.roomId.equals(roomId) & t.createdAt.isNotNull())
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)])
      ..limit(1);

    final row = await query.getSingleOrNull();
    return row?.createdAt?.toUtc();
  }
}
