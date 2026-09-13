import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/catchup_repository.dart';
import 'package:flycomm/room/config_repository.dart';
import 'package:flycomm/room/device_identity.dart';
import 'package:flycomm/room/room_repository.dart';
import 'package:flycomm/room/server_clock.dart';

import 'env.dart';

void main() {
  late CatchupRepository catchup;
  late ServerClock clock;
  late int roomId;
  late Duration catchupWindow;

  setUpAll(() async {
    final api = ApiClient(baseUrl: httpBase);
    clock = ServerClock();

    final seeded = seededDevices['rodrigo']!;
    await AuthRepository(api: api).authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );

    catchupWindow =
        (await ConfigRepository(api: api, clock: clock).fetch()).budgets.catchupWindow;
    roomId = (await RoomRepository(api: api).join('FLY-TEST')).id;
    catchup = CatchupRepository(api: api, clock: clock);
  });

  test('sem since, a janela é a do servidor', () async {
    final result = await catchup.fetch(roomId);

    final width = result.serverTime.difference(result.windowStart);
    expect(width.inMilliseconds,
        closeTo(catchupWindow.inMilliseconds, 1000));
    expect(result.hasGapSince(null), isFalse);
  });

  test('since de dez minutos atrás é ignorado e vira buraco', () async {
    final since = clock.now().subtract(const Duration(minutes: 10));

    final result = await catchup.fetch(roomId, since: since);

    expect(result.hasGapSince(since), isTrue,
        reason: 'ausência longa não é coberta de propósito');
    expect(result.windowStart.isAfter(since), isTrue);
  });

  test('since recente não é buraco', () async {
    final since = clock.now().subtract(const Duration(seconds: 5));

    final result = await catchup.fetch(roomId, since: since);

    expect(result.hasGapSince(since), isFalse);
  });

  test('a rajada recém-publicada aparece no catch-up', () async {
    // Rode antes deste teste, em outro terminal:
    //   cd ../flycomm-server && docker compose exec app \
    //     php artisan flycomm:demo-burst 255 --from=510
    final result = await catchup.fetch(roomId);

    if (result.messages.isEmpty) {
      markTestSkipped('nenhuma rajada fresca; dispare flycomm:demo-burst');
      return;
    }

    final burst = result.messages.first.burstId;
    final segments = result.messages.where((m) => m.burstId == burst).toList();

    expect(segments.map((m) => m.index), orderedEquals(
        List.generate(segments.length, (i) => i)),
        reason: 'os segmentos de uma rajada chegam em ordem de índice');
  });
}
