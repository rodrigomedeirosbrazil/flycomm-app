import 'package:flutter/foundation.dart';

/// Narra o caminho de uma fala recebida: ingest → download → disco → fila →
/// reprodução. Só em debug — o `assert` some inteiro no release, argumento
/// incluído, então o custo em produção é zero.
///
/// Existe porque o sintoma e a causa ficam longe um do outro neste caminho.
/// "Todas as mensagens chegam atrasadas e não tocam" foi, em momentos
/// diferentes, um player liberado cedo demais, um ingest duplicado e uma URL
/// apontando para `localhost` — três causas, um sintoma só. O log do servidor
/// não ajuda: ele é cego para tudo o que acontece dentro do app.
///
/// A regra ao mexer aqui: cada etapa narra quando **começa** e quando
/// **termina**. É o intervalo que falta que diz onde parou.
void trace(String message) {
  assert(() {
    debugPrint('[flycomm] $message');
    return true;
  }());
}
