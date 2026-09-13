/// O relógio contra o qual toda idade é medida.
///
/// Relógio de celular deriva. Comparar `created_at` com DateTime.now() funciona
/// na bancada e falha em campo: um aparelho adiantado descarta mensagens boas,
/// um atrasado toca mensagens vencidas. O desvio sai do campo `server_time` que
/// GET /config e GET /rooms/{id}/catchup devolvem, e é reaplicado a cada
/// resposta — é de graça e corrige deriva ao longo do voo.
class ServerClock {
  ServerClock({DateTime Function()? localNow})
      : _localNow = localNow ?? (() => DateTime.now().toUtc());

  final DateTime Function() _localNow;

  Duration _skew = Duration.zero;
  bool _synced = false;

  bool get isSynced => _synced;
  Duration get skew => _skew;

  /// [receivedAt] é o relógio local no instante em que a resposta chegou — o
  /// mesmo instante a que [serverTime] se refere, a menos da metade do
  /// round-trip, que numa LAN é ruído comparado ao prazo de 30 s.
  void sync({required DateTime serverTime, required DateTime receivedAt}) {
    _skew = serverTime.toUtc().difference(receivedAt.toUtc());
    _synced = true;
  }

  DateTime now() => _localNow().toUtc().add(_skew);

  Duration ageOf(DateTime createdAt) => now().difference(createdAt.toUtc());
}
