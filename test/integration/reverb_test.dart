import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/env.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/device_identity.dart';
import 'package:flycomm/room/models.dart';
import 'package:flycomm/room/reverb_client.dart';
import 'package:flycomm/room/room_repository.dart';

import 'env.dart';

void main() {
  late ApiClient api;
  late ReverbClient reverb;
  late Room room;

  setUpAll(() async {
    api = ApiClient(baseUrl: httpBase);

    // Este arquivo usa `marina`: cada POST /auth/device revoga o token anterior
    // daquele dispositivo, então dois arquivos de teste com o mesmo identifier
    // se derrubariam mutuamente.
    final seeded = seededDevices['marina']!;
    await AuthRepository(api: api).authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );

    room = await RoomRepository(api: api).join('FLY-TEST');

    reverb = ReverbClient(
      api: api,
      appKey: Env.wsKey,
      host: Env.wsHost,
      port: Env.wsPort,
    );
  });

  tearDownAll(() => reverb.dispose());

  test('assina o presence channel e enxerga os membros', () async {
    final connected = reverb.connectionState
        .firstWhere((s) => s == ReverbConnection.connected);
    final firstPresence = reverb.presence.first;

    await reverb.connect(room);

    await connected.timeout(const Duration(seconds: 15));
    final presence = await firstPresence.timeout(const Duration(seconds: 15));

    expect(presence.members, isNotEmpty,
        reason: 'nós mesmos já contamos como membro presente');
    expect(presence.members.map((m) => m.id), contains(isA<int>()));
  });

  test('o canal no fio é presence-room.{id}', () {
    expect(presenceChannelFor(255), 'presence-room.255');
  });

  test('recebe message.new com o metadado completo', () async {
    await reverb.connect(room);
    await reverb.connectionState
        .firstWhere((s) => s == ReverbConnection.connected)
        .timeout(const Duration(seconds: 15));

    final next = reverb.messages.first;

    // A rajada é publicada por outro membro enquanto estamos assinados.
    // Dispare em outro terminal, dentro de 30 s:
    //   cd ../flycomm-server && docker compose exec app \
    //     php artisan flycomm:demo-burst 255 --from=511
    final message = await next.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw StateError(
        'nenhuma message.new em 30 s — dispare flycomm:demo-burst 255 --from=511',
      ),
    );

    expect(message.roomId, room.id);
    expect(message.burstId, isNotEmpty);
    expect(message.createdAt.isUtc, isTrue);
    expect(message.audioUrl, contains('/messages/${message.id}/audio'));
  }, skip: 'exige disparar a rajada à mão; ver o comentário acima');
}
