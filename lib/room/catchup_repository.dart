import 'api_client.dart';
import 'models.dart';
import 'server_clock.dart';

class CatchupResult {
  const CatchupResult({
    required this.serverTime,
    required this.windowStart,
    required this.messages,
  });

  final DateTime serverTime;

  /// `agora - catchup_window`, sempre — e não o piso efetivo. É justamente por
  /// isso que dá para detectar buraco: se o campo devolvesse o piso efetivo,
  /// ele seria igual ao `since` sempre que o `since` fosse recente, e o buraco
  /// nunca apareceria.
  final DateTime windowStart;

  final List<RoomMessage> messages;

  /// Houve buraco no histórico: o app pediu desde um ponto que a janela não
  /// alcança, e o que existiu entre os dois não vai chegar nunca. Sem isso o
  /// buraco existiria sem nenhum indício.
  bool hasGapSince(DateTime? since) =>
      since != null && since.toUtc().isBefore(windowStart);

  factory CatchupResult.fromJson(Map<String, dynamic> json) => CatchupResult(
        serverTime: DateTime.parse(json['server_time'] as String).toUtc(),
        windowStart: DateTime.parse(json['window_start'] as String).toUtc(),
        messages: (json['messages'] as List<dynamic>)
            .map((e) => RoomMessage.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

class CatchupRepository {
  CatchupRepository({required this.api, required this.clock});

  final ApiClient api;
  final ServerClock clock;

  /// [since] é o `created_at` da última mensagem vista — um carimbo que o
  /// próprio servidor emitiu, nunca o relógio do celular.
  Future<CatchupResult> fetch(int roomId, {DateTime? since}) async {
    final response = await api.send<Map<String, dynamic>>(
      'GET',
      '/rooms/$roomId/catchup',
      query: {
        if (since != null) 'since': since.toUtc().toIso8601String(),
      },
    );
    final receivedAt = DateTime.now().toUtc();

    final result = CatchupResult.fromJson(response.data!);
    clock.sync(serverTime: result.serverTime, receivedAt: receivedAt);

    return result;
  }
}
