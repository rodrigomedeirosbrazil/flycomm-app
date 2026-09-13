import 'dart:async';

import '../history/history_repository.dart';
import 'api_client.dart';
import 'budgets.dart';
import 'message_api.dart';
import 'models.dart';
import 'server_clock.dart';

/// Um segmento esperando para subir, mais o que aprendemos tentando.
class _Pending {
  _Pending(this.segment);

  final OutgoingSegment segment;
  final Completer<void> done = Completer<void>();

  int attempts = 0;

  /// Quando a próxima tentativa pode acontecer; nulo é "agora".
  DateTime? notBefore;
}

/// Sobe os segmentos insistindo durante a janela de entrega, com o que ainda
/// pode ser ouvido ao vivo na frente do que já não pode.
///
/// **A mensagem sobe mesmo depois de vencida** (spec 2.1). Ela não toca em
/// ninguém — quem recebe decide isso pela idade da fala —, mas entra no
/// histórico da sala, e sem isso quem ficou sem rede simplesmente desaparece do
/// registro dos outros, sem deixar indício de que falou.
///
/// O que impede isso de virar a fila de saída persistente que a spec recusou é
/// o teto: passado o `deliveryDeadline`, contado da captura, o app desiste de
/// vez e a mensagem fica como NÃO ENTREGUE. A fila vive em memória e morre com
/// o processo, de propósito. Ela precisa sobreviver à navegação entre telas —
/// minutos de insistência passam por várias —, e por isso mora no escopo do
/// app, não na sessão de sala; mas não sobrevive ao fechamento do app.
///
/// **Fresco na frente.** A cada rodada o trabalhador escolhe primeiro um
/// segmento cuja fala ainda cabe no `playbackDeadline`, porque esse ainda pode
/// ser ouvido ao vivo, e o atrasado por definição não pode. A escolha é refeita
/// a cada rodada em vez de fixada na entrada: um segmento que falha por trinta
/// segundos deixa de ser fresco sozinho e sai da frente dos que vieram depois,
/// em vez de segurar a conversa do presente para registrar o passado.
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

  final _pending = <_Pending>[];

  Future<void>? _worker;
  Completer<void>? _sleeping;

  /// Quantos segmentos ainda esperam um desfecho. Existe para os testes e para
  /// a tela saber que há coisa em trânsito.
  int get pendingCount => _pending.length;

  /// Entrega o segmento à fila e completa quando ele chega a um desfecho:
  /// entregue, entregue atrasada ou não entregue. Nunca lança — a falha de um
  /// upload é informação para o piloto, registrada no histórico, não um erro
  /// que a tela precise tratar.
  Future<void> upload(OutgoingSegment segment) {
    final pending = _Pending(segment);
    _pending.add(pending);

    // Um segmento fresco que chega enquanto o trabalhador dorme entre
    // tentativas de um atrasado não pode esperar o cochilo terminar.
    _wake();
    _worker ??= _run().whenComplete(() => _worker = null);

    return pending.done.future;
  }

  Future<void> _run() async {
    while (_pending.isNotEmpty) {
      await _giveUpOnExpired();
      if (_pending.isEmpty) break;

      final next = _pickReady();

      if (next == null) {
        final nap = _timeUntilSomethingIsReady();
        if (nap == null) break;
        await _sleep(nap);
        continue;
      }

      await _attempt(next);
    }
  }

  /// Passado o teto, desiste de vez: o piloto precisa saber que ninguém o
  /// ouviu, e que desta vez nem ficou registrado.
  Future<void> _giveUpOnExpired() async {
    for (final pending in List<_Pending>.from(_pending)) {
      if (clock.now().isBefore(_deadlineOf(pending))) continue;
      await history.markUndelivered(pending.segment.id);
      _finish(pending);
    }
  }

  /// Fresco primeiro, depois atrasado; dentro de cada pista, o mais antigo.
  _Pending? _pickReady() {
    final now = clock.now();
    final ready = _pending
        .where((p) => p.notBefore == null || !p.notBefore!.isAfter(now))
        .toList()
      ..sort((a, b) => a.segment.capturedAt.compareTo(b.segment.capturedAt));

    if (ready.isEmpty) return null;

    return ready.firstWhere(
      (p) => _ageOfSpeech(p) <= budgets.playbackDeadline,
      orElse: () => ready.first,
    );
  }

  Duration? _timeUntilSomethingIsReady() {
    final now = clock.now();
    Duration? soonest;

    for (final pending in _pending) {
      final at = pending.notBefore;
      if (at == null) return Duration.zero;

      final gap = at.difference(now);
      if (soonest == null || gap < soonest) soonest = gap;
    }

    return soonest;
  }

  Future<void> _attempt(_Pending pending) async {
    if (pending.attempts == 0) await history.markSending(pending.segment.id);
    pending.attempts++;

    try {
      final accepted = await _publish(pending.segment);
      await history.markDelivered(
        pending.segment.id,
        accepted,
        // Se ao ser publicada a fala já estava vencida, nenhum receptor podia
        // tê-la tocado: entrou no histórico dos outros, mas ninguém ouviu.
        wasLate: accepted.createdAt
                .difference(pending.segment.capturedAt.toUtc()) >
            budgets.playbackDeadline,
      );
      _finish(pending);
    } on ApiException catch (e) {
      // 422 e 409 são recusa de conteúdo, não de rede: retentar reproduz o
      // mesmo erro até a janela fechar.
      if (e.isValidation || e.isConflict) {
        await history.markUndelivered(pending.segment.id);
        _finish(pending);
        return;
      }
      pending.notBefore = clock.now().add(_backoff(pending.attempts));
    } catch (_) {
      pending.notBefore = clock.now().add(_backoff(pending.attempts));
    }
  }

  void _finish(_Pending pending) {
    _pending.remove(pending);
    if (!pending.done.isCompleted) pending.done.complete();
  }

  DateTime _deadlineOf(_Pending pending) =>
      pending.segment.capturedAt.toUtc().add(budgets.deliveryDeadline);

  Duration _ageOfSpeech(_Pending pending) =>
      clock.ageOf(pending.segment.capturedAt);

  /// Rápido enquanto a fala ainda é fresca, espaçado depois.
  ///
  /// Os primeiros cinco degraus cabem dentro do prazo de reprodução, que é onde
  /// insistir ainda pode salvar a mensagem como comunicação ao vivo. Passado
  /// isso, o teto de 30 s é o que faz a janela de entrega caber numa dúzia de
  /// tentativas em vez de uma centena — um aparelho sem rede não fica melhor
  /// por ser perguntado mais vezes.
  Duration _backoff(int attempt) => Duration(
        milliseconds: (500 * (1 << (attempt - 1))).clamp(500, 30000),
      );

  Future<void> _sleep(Duration duration) async {
    if (duration <= Duration.zero) return;

    final sleeping = _sleeping = Completer<void>();
    await Future.any([_wait(duration), sleeping.future]);
    _sleeping = null;
  }

  void _wake() {
    final sleeping = _sleeping;
    if (sleeping != null && !sleeping.isCompleted) sleeping.complete();
  }
}
