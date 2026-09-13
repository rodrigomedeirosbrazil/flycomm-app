import 'dart:async';
import 'dart:collection';

import '../room/budgets.dart';
import '../room/server_clock.dart';

class QueuedItem {
  const QueuedItem({required this.messageId, required this.createdAt});

  final String messageId;

  /// A autoridade de frescor: o carimbo do servidor, nunca o do celular.
  final DateTime createdAt;
}

/// O app se comporta como um rádio: uma voz por vez, nunca sobreposta, em
/// ordem de chegada.
///
/// Três regras, todas da seção 2.1 da spec:
///
/// - o prazo é verificado no momento de desenfileirar, não de enfileirar: se a
///   fila tem oito mensagens, a cauda já venceu antes de chegar a vez
/// - item vencido sai SEM tocar e é anunciado em [dropped], para virar
///   "atrasada" no histórico — ouvível por toque, nunca automaticamente
/// - enquanto [pttHeld], nada toca: meio-duplex
class PlaybackQueue {
  PlaybackQueue({
    required this.clock,
    required this.budgets,
    required Future<void> Function(QueuedItem item) play,
  }) : _play = play;

  final ServerClock clock;
  final Budgets budgets;
  final Future<void> Function(QueuedItem item) _play;

  final Queue<QueuedItem> _items = Queue<QueuedItem>();
  final StreamController<QueuedItem> _dropped =
      StreamController<QueuedItem>.broadcast();

  Future<void>? _pumping;
  bool _pttHeld = false;

  /// Os itens que saíram da fila sem tocar por terem passado do prazo.
  Stream<QueuedItem> get dropped => _dropped.stream;

  int get length => _items.length;

  bool get pttHeld => _pttHeld;

  set pttHeld(bool value) {
    if (_pttHeld == value) return;
    _pttHeld = value;
    if (!value) _pump();
  }

  /// Completa quando não há mais nada a fazer agora. Existe para os testes e
  /// para o desligamento ordenado — a UI nunca espera por isto.
  Future<void> get drained => _pumping ?? Future<void>.value();

  void enqueue(QueuedItem item) {
    _items.add(item);
    _pump();
  }

  void _pump() {
    if (_pumping != null || _pttHeld) return;
    _pumping = _drain().whenComplete(() => _pumping = null);
  }

  Future<void> _drain() async {
    while (_items.isNotEmpty && !_pttHeld) {
      final item = _items.removeFirst();

      if (clock.ageOf(item.createdAt) > budgets.playbackDeadline) {
        _dropped.add(item);
        continue;
      }

      await _play(item);
    }
  }

  Future<void> dispose() async {
    _items.clear();
    await _dropped.close();
  }
}
