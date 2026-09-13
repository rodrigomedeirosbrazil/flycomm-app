import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// O ciclo de vida de uma mensagem no histórico local.
///
/// Saída: gravada → enviando → entregue, ou → não entregue.
/// Entrada: recebida (tocada) ou atrasada (saiu da fila sem tocar, ouvível
/// por toque, nunca automaticamente).
enum MessageState {
  recorded,
  sending,
  delivered,
  undelivered,
  received,
  late,
}

enum MessageDirection { outgoing, incoming }

@DataClassName('LocalMessage')
class LocalMessages extends Table {
  /// uuid gerado pelo app na saída, id do servidor na entrada. É o mesmo id nos
  /// dois lados: é o que torna o upload idempotente.
  TextColumn get id => text()();

  IntColumn get roomId => integer()();
  TextColumn get burstId => text()();
  IntColumn get segmentIndex => integer().named('index')();

  IntColumn get authorId => integer().nullable()();
  TextColumn get authorName => text().nullable()();

  IntColumn get durationMs => integer()();
  TextColumn get origin => text()();
  TextColumn get format => text()();
  IntColumn get sizeBytes => integer().nullable()();

  /// Do cliente, só para o histórico.
  DateTimeColumn get capturedAt => dateTime().nullable()();

  /// Do servidor: a autoridade de frescor. Nulo enquanto a mensagem não foi
  /// aceita — uma mensagem não entregue nunca teve um `created_at`.
  DateTimeColumn get createdAt => dateTime().nullable()();

  TextColumn get direction => textEnum<MessageDirection>()();
  TextColumn get state => textEnum<MessageState>()();

  /// Caminho do arquivo no dispositivo. Nulo enquanto o download não terminou.
  TextColumn get audioPath => text().nullable()();

  /// Ordena o histórico mesmo quando createdAt é nulo.
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [LocalMessages])
class HistoryDatabase extends _$HistoryDatabase {
  HistoryDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'flycomm_history'));

  @override
  int get schemaVersion => 1;
}
