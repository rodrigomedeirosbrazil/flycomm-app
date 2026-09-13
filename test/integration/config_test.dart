import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/config_repository.dart';
import 'package:flycomm/room/server_clock.dart';

import 'env.dart';

void main() {
  late ConfigRepository repo;
  late ServerClock clock;

  setUp(() {
    clock = ServerClock();
    repo = ConfigRepository(
      api: ApiClient(baseUrl: httpBase),
      clock: clock,
    );
  });

  test('GET /config devolve os cinco orçamentos e as duas faixas', () async {
    final config = await repo.fetch();

    expect(config.budgets.segmentMax, const Duration(seconds: 5));
    expect(config.budgets.playbackDeadline.inMilliseconds, greaterThan(0));
    expect(config.budgets.catchupWindow, greaterThan(config.budgets.playbackDeadline),
        reason: 'a janela de catch-up é maior que o prazo de propósito: o '
            'excedente não toca, mas preenche o histórico (spec 2.1)');
    expect(config.frequencyBands, hasLength(2));
    expect(config.isFrequencyValid(145550000), isTrue);
  });

  test('GET /config sincroniza o relógio com desvio pequeno numa LAN', () async {
    await repo.fetch();

    expect(clock.isSynced, isTrue);
    expect(clock.skew.abs(), lessThan(const Duration(seconds: 5)),
        reason: 'servidor e Mac de bancada não deveriam divergir muito; se '
            'divergirem, o relógio de um dos dois está errado');
  });
}
