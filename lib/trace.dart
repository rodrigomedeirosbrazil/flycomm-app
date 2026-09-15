import 'package:flutter/foundation.dart';

/// Narra o caminho de uma fala recebida: ingest → download → disco → fila →
/// reprodução. A impressão é só em debug: o `assert` some no release.
///
/// **O argumento não some.** `trace` recebe uma `String` já pronta, então a
/// interpolação é avaliada na chamada, em release também — só o `debugPrint`
/// é que desaparece. O custo em produção é o de montar as strings, que é
/// pequeno mas não é zero, e o que quer que a interpolação faça acontece de
/// verdade: foi assim que um `substring` num id curto virou "não deu para
/// receber uma fala".
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
