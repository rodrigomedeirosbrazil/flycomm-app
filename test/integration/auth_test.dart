import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/device_identity.dart';

import 'env.dart';

void main() {
  late ApiClient api;
  late AuthRepository auth;

  setUp(() {
    api = ApiClient(baseUrl: httpBase);
    auth = AuthRepository(api: api);
  });

  test('autentica com um device semeado e recebe token', () async {
    final seeded = seededDevices['rodrigo']!;

    final user = await auth.authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );

    expect(user.id, greaterThan(0));
    expect(user.displayName, seeded.name);
    expect(api.token, isNotEmpty);
  });

  test('recuperação ignora o display_name enviado', () async {
    final seeded = seededDevices['tiago']!;
    final credentials =
        DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret);

    final first = await auth.authenticate(credentials, displayName: seeded.name);
    final second =
        await auth.authenticate(credentials, displayName: 'Nome Descartado');

    expect(second.id, first.id, reason: 'mesma credencial, mesmo usuário');
    expect(second.displayName, seeded.name,
        reason: 'o nome canônico vive no servidor; quem o muda é PATCH /me');
  });

  test('identifier e secret gerados cabem nos limites do servidor', () async {
    final generated = await DeviceIdentity(storage: _MemoryStorage()).loadOrCreate();

    expect(generated.identifier.length, inInclusiveRange(16, 128));
    expect(generated.secret.length, inInclusiveRange(32, 72),
        reason: 'o teto de 72 é o do bcrypt: acima disso ele trunca em silêncio');

    final user = await auth.authenticate(generated, displayName: 'Device Novo');
    expect(user.displayName, 'Device Novo');
  });

  test('segredo errado é recusado', () async {
    final seeded = seededDevices['marina']!;

    await expectLater(
      auth.authenticate(
        DeviceCredentials(
          identifier: seeded.identifier,
          secret: 'errado-mas-com-tamanho-suficiente-para-passar-na-validacao',
        ),
        displayName: seeded.name,
      ),
      throwsA(isA<ApiException>()),
    );
  });
}

/// FlutterSecureStorage não funciona em `flutter test` (não há plataforma).
/// Este duplo guarda em memória, que é tudo que o teste precisa.
// ignore: subtype_of_sealed_class
class _MemoryStorage implements FlutterSecureStorage {
  final _values = <String, String>{};

  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => _values[key];

  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
