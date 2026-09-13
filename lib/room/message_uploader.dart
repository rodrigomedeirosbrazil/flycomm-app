import 'dart:async';

import '../history/history_repository.dart';
import 'api_client.dart';
import 'budgets.dart';
import 'message_api.dart';
import 'models.dart';
import 'server_clock.dart';

/// Sobe um segmento insistindo durante a janela de validade e desistindo
/// depois. Vive em memória e morre com o processo, de propósito: não existe
/// fila de saída persistente, porque guardar uma mensagem para subir "quando
/// der" só faria sentido se alguém fosse ouvi-la.
class MessageUploader {
  MessageUploader({
    required this.clock,
    required this.budgets,
    required this.history,
    required Future<RoomMessage> Function(OutgoingSegment) publish,
    Future<void> Function(Duration)? wait,
  })  : _publish = publish,
        _wait = wait ?? Future<void>.delayed;

  final ServerClock clock;
  final Budgets budgets;
  final HistoryRepository history;
  final Future<RoomMessage> Function(OutgoingSegment) _publish;
  final Future<void> Function(Duration) _wait;

  /// A janela de validade. Ver a seção 0.2 do plano: passado o prazo de
  /// reprodução ninguém tocaria o áudio, então insistir é gastar bateria e
  /// rádio por nada. Trocar por `catchupWindow` é mudar esta linha.
  Duration get validityWindow => budgets.playbackDeadline;

  Future<void> upload(OutgoingSegment segment) async {
    final deadline = segment.capturedAt.toUtc().add(validityWindow);
    var attempt = 0;

    while (clock.now().isBefore(deadline)) {
      if (attempt == 0) await history.markSending(segment.id);
      attempt++;

      try {
        final accepted = await _publish(segment);
        await history.markDelivered(segment.id, accepted);
        return;
      } on ApiException catch (e) {
        // 422 e 409 são recusa de conteúdo, não de rede: retentar reproduz o
        // mesmo erro até a janela fechar.
        if (e.isValidation || e.isConflict) break;
        await _wait(_backoff(attempt));
      } catch (_) {
        await _wait(_backoff(attempt));
      }
    }

    await history.markUndelivered(segment.id);
  }

  /// Cresce até 4 s e para de crescer: com uma janela de 30 s, esperar mais
  /// que isso desperdiça tentativas que ainda caberiam.
  Duration _backoff(int attempt) => Duration(
        milliseconds: (500 * (1 << (attempt - 1))).clamp(500, 4000),
      );
}
