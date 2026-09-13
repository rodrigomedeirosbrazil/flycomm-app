/// Os orçamentos de tempo da seção 2 da spec.
///
/// Chegam de GET /config e nunca são constantes no código: os valores são
/// chutes a calibrar em campo, e calibrar não pode depender da loja.
class Budgets {
  const Budgets({
    required this.playbackDeadline,
    required this.radioRelayDeadline,
    required this.deliveryDeadline,
    required this.segmentMax,
    required this.catchupWindow,
    required this.blobTtl,
  });

  final Duration playbackDeadline;
  final Duration radioRelayDeadline;

  /// Até quando o app insiste em subir antes de desistir de vez. É o teto que
  /// impede a entrega atrasada de virar fila de saída persistente: sem ele o
  /// app tentaria para sempre.
  final Duration deliveryDeadline;

  final Duration segmentMax;
  final Duration catchupWindow;
  final Duration blobTtl;

  factory Budgets.fromJson(Map<String, dynamic> json) => Budgets(
        playbackDeadline: Duration(milliseconds: json['playback_deadline_ms'] as int),
        radioRelayDeadline: Duration(milliseconds: json['radio_relay_deadline_ms'] as int),
        deliveryDeadline: Duration(milliseconds: json['delivery_deadline_ms'] as int),
        segmentMax: Duration(milliseconds: json['segment_max_ms'] as int),
        catchupWindow: Duration(milliseconds: json['catchup_window_ms'] as int),
        blobTtl: Duration(milliseconds: json['blob_ttl_ms'] as int),
      );
}

class FrequencyBand {
  const FrequencyBand({required this.minHz, required this.maxHz});

  final int minHz;
  final int maxHz;

  bool contains(int hz) => hz >= minHz && hz <= maxHz;

  factory FrequencyBand.fromJson(Map<String, dynamic> json) => FrequencyBand(
        minHz: json['min_hz'] as int,
        maxHz: json['max_hz'] as int,
      );
}

class ServerConfig {
  const ServerConfig({
    required this.budgets,
    required this.frequencyBands,
    required this.serverTime,
  });

  final Budgets budgets;
  final List<FrequencyBand> frequencyBands;
  final DateTime serverTime;

  /// Frequência é inteiro em Hz, nunca float: comparar 145.55 MHz em ponto
  /// flutuante é convidar erro de arredondamento numa checagem de faixa.
  bool isFrequencyValid(int hz) =>
      frequencyBands.any((band) => band.contains(hz));

  /// Lê a frequência do jeito que o piloto digitou.
  ///
  /// Aceita `145,550`, `145.550`, `145550` (kHz) e `145550000` (Hz), além de
  /// `146` — porque o piloto está com pressa, às vezes de luva, e o teclado
  /// decimal do iOS em pt-BR oferece vírgula enquanto `double.parse` quer
  /// ponto.
  ///
  /// Não é adivinhação: as faixas do rádio são estreitas (136–174 e
  /// 400–470 MHz), então das três leituras possíveis no máximo uma cai dentro
  /// de alguma. Tentamos MHz, kHz e Hz nessa ordem e ficamos com a primeira
  /// válida. Devolve null quando o texto não é número ou quando nenhuma
  /// leitura cai numa faixa.
  int? frequencyHzFromInput(String raw) {
    final number = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (number == null) return null;

    for (final multiplier in const [1000000, 1000, 1]) {
      final hz = (number * multiplier).round();
      if (isFrequencyValid(hz)) return hz;
    }

    return null;
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        budgets: Budgets.fromJson(json['budgets'] as Map<String, dynamic>),
        frequencyBands: (json['frequency_bands'] as List<dynamic>)
            .map((e) => FrequencyBand.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        serverTime: DateTime.parse(json['server_time'] as String).toUtc(),
      );
}
