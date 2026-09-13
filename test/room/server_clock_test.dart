import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/server_clock.dart';

void main() {
  test('sem sincronizar, não finge saber a hora do servidor', () {
    final clock = ServerClock(localNow: () => DateTime.utc(2026, 9, 13, 12));
    expect(clock.isSynced, isFalse);
  });

  test('a idade é medida contra o relógio do servidor, não o local', () {
    // O celular está 90 s ADIANTADO em relação ao servidor.
    final localNow = DateTime.utc(2026, 9, 13, 12, 0, 0);
    final clock = ServerClock(localNow: () => localNow);

    clock.sync(
      serverTime: DateTime.utc(2026, 9, 13, 11, 58, 30),
      receivedAt: localNow,
    );

    expect(clock.isSynced, isTrue);
    expect(clock.now(), DateTime.utc(2026, 9, 13, 11, 58, 30));

    // Mensagem criada 10 s atrás pelo relógio do SERVIDOR.
    final createdAt = DateTime.utc(2026, 9, 13, 11, 58, 20);

    // Contra o relógio do servidor: 10 s, fresca.
    expect(clock.ageOf(createdAt), const Duration(seconds: 10));
    // Contra o relógio local seriam 100 s, e ela teria sido descartada à toa.
    expect(localNow.difference(createdAt), const Duration(seconds: 100));
  });

  test('o relógio local andando move o relógio do servidor junto', () {
    var fake = DateTime.utc(2026, 9, 13, 12, 0, 0);
    final clock = ServerClock(localNow: () => fake);
    clock.sync(
      serverTime: DateTime.utc(2026, 9, 13, 11, 58, 30),
      receivedAt: fake,
    );

    fake = fake.add(const Duration(seconds: 5));

    expect(clock.now(), DateTime.utc(2026, 9, 13, 11, 58, 35));
  });

  test('sincronizar de novo substitui o desvio, não acumula', () {
    var fake = DateTime.utc(2026, 9, 13, 12, 0, 0);
    final clock = ServerClock(localNow: () => fake);

    clock.sync(serverTime: DateTime.utc(2026, 9, 13, 11, 58, 30), receivedAt: fake);
    clock.sync(serverTime: DateTime.utc(2026, 9, 13, 12, 0, 2), receivedAt: fake);

    expect(clock.now(), DateTime.utc(2026, 9, 13, 12, 0, 2));
  });
}
