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
/// **termina**. É o intervalo que falta que diz onde parou — e por isso cada
/// linha carimba a hora. Sem o carimbo dá para ver a ordem dos eventos e não
/// a distância entre eles, que é metade da pergunta: uma fala de 5 s que
/// termina 800 ms depois de começar foi cortada; uma que termina em 5 s e só
/// é seguida pela próxima dois segundos depois não foi cortada, faltou buffer.
void trace(String message) {
  assert(() {
    final now = DateTime.now();
    String pad(int value, int width) => value.toString().padLeft(width, '0');
    final stamp = '${pad(now.minute, 2)}:${pad(now.second, 2)}.'
        '${pad(now.millisecond, 3)}';

    debugPrint('[flycomm $stamp] $message');
    return true;
  }());
}
