import 'database.dart';

/// Os segmentos da rajada recebida mais nova que dá para tocar, em ordem.
///
/// [newestFirst] é o que `HistoryRepository.watchRoom` entrega: do mais novo
/// para o mais velho.
///
/// **A rajada, e não o último segmento.** Uma fala de 12 s são três mensagens
/// com o mesmo `burst_id` e índices 0, 1 e 2. Repetir só a mais nova devolveria
/// os últimos dois segundos de uma frase — o suficiente para o botão parecer
/// funcionar e não entregar a informação, que é o pior dos dois.
///
/// Segmento sem `audioPath` fica de fora e a rajada toca sem ele: o blob vence
/// no servidor em minutos, parcial é melhor que nada, e a linha do histórico já
/// mostra que falta.
List<LocalMessage> lastIncomingBurst(List<LocalMessage> newestFirst) {
  final playable = newestFirst.where((message) =>
      message.direction == MessageDirection.incoming &&
      message.audioPath != null);

  if (playable.isEmpty) return const [];

  final burstId = playable.first.burstId;

  return playable.where((message) => message.burstId == burstId).toList()
    ..sort((a, b) => a.segmentIndex.compareTo(b.segmentIndex));
}
