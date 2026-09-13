import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/device_identity.dart';
import 'package:flycomm/room/room_repository.dart';

import 'env.dart';

void main() {
  late RoomRepository rooms;

  setUpAll(() async {
    final api = ApiClient(baseUrl: httpBase);
    final seeded = seededDevices['rodrigo']!;
    await AuthRepository(api: api).authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );
    rooms = RoomRepository(api: api);
  });

  test('entra por código e enxerga os membros', () async {
    final room = await rooms.join('FLY-TEST');

    expect(room.inviteCode, 'FLY-TEST');
    expect(room.members.length, greaterThanOrEqualTo(1));
    expect(room.members.every((m) => m.role == 'member'), isTrue);
  });

  test('o código é normalizado: minúscula, sem hífen, sem prefixo', () async {
    final canonical = await rooms.join('FLY-TEST');

    for (final variant in ['fly-test', 'FLYTEST', 'test', 'Test']) {
      final room = await rooms.join(variant);
      expect(room.id, canonical.id, reason: '"$variant" deveria cair na mesma sala');
    }
  });

  test('minhas salas vêm embrulhadas em data', () async {
    await rooms.join('FLY-TEST');
    final mine = await rooms.mine();

    expect(mine, isNotEmpty);
    expect(mine.map((r) => r.inviteCode), contains('FLY-TEST'));
  });

  test('frequência é inteiro em Hz e pode ser limpa', () async {
    final created = await rooms.create(name: 'Sala de teste', frequencyHz: 145550000);
    expect(created.frequencyHz, 145550000);

    final cleared = await rooms.update(created.id, clearFrequency: true);
    expect(cleared.frequencyHz, isNull,
        reason: 'nullable descreve "ainda não combinamos a frequência"');

    final retuned = await rooms.update(created.id, frequencyHz: 446000000);
    expect(retuned.frequencyHz, 446000000);
  });

  test('frequência fora das faixas do rádio é recusada com 422', () async {
    await expectLater(
      rooms.create(name: 'Fora de faixa', frequencyHz: 200000000),
      throwsA(isA<ApiException>().having((e) => e.isValidation, 'isValidation', isTrue)),
    );
  });

  test('qualquer membro renomeia: a sala é plana', () async {
    final room = await rooms.join('FLY-TEST');
    final renamed = await rooms.update(room.id, name: 'Voo de domingo');

    expect(renamed.name, 'Voo de domingo');
  });
}
