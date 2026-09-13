import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// O ciclo de vida de uma mensagem no histórico local.
///
/// Saída: gravada → enviando → entregue, → entregue atrasada, ou → não
/// entregue.
/// Entrada: recebida (tocada) ou atrasada (saiu da fila sem tocar, ouvível
/// por toque, nunca automaticamente).
///
/// [deliveredLate] é o desfecho que a seção 2.1 da spec criou: a mensagem subiu
/// depois do prazo, entrou no histórico dos outros e não tocou em ninguém. Para
/// o piloto ela diz o mesmo que [undelivered] sobre o presente — ninguém te
/// ouviu, use o rádio — e o contrário sobre o registro: esta ficou.
enum MessageState {
  recorded,
  sending,
  delivered,
  deliveredLate,
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

  /// Do cliente: quando isto foi dito. É a idade da fala, e é por ela que o
  /// app decide se toca (spec 2.1). Nulo só quando a origem é `radio`, que não
  /// tem cliente para carimbar.
  DateTimeColumn get capturedAt => dateTime().nullable()();

  /// Do servidor: quando isto chegou. Ordena o transporte e é o `since` do
  /// catch-up. Nulo enquanto a mensagem não foi aceita — uma mensagem não
  /// entregue nunca teve um `created_at`.
  DateTimeColumn get createdAt => dateTime().nullable()();

  TextColumn get direction => textEnum<MessageDirection>()();
  TextColumn get state => textEnum<MessageState>()();

  /// Caminho do arquivo no dispositivo. Nulo enquanto o download não terminou.
  TextColumn get audioPath => text().nullable()();

  /// A posição na linha do tempo: `capturedAt`, com queda para `createdAt`
  /// quando ele não existe. É o que põe a mensagem atrasada onde ela foi
  /// gravada em vez de no fim da lista — jogá-la no fim contaria uma história
  /// errada sobre a ordem em que as coisas foram ditas.
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
