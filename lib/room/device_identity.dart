import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Credencial do tipo `device`: o app gera o par uma vez e o guarda no
/// armazenamento seguro da plataforma.
///
/// A dívida é conhecida e aceita: trocou de celular, perdeu tudo. Ela existe
/// porque reivindicar a conta depois é inserir uma linha em `credentials`
/// apontando para o mesmo user_id — não uma migração de `users`.
class DeviceCredentials {
  const DeviceCredentials({required this.identifier, required this.secret});

  final String identifier;
  final String secret;
}

class DeviceIdentity {
  DeviceIdentity({FlutterSecureStorage? storage, Random? random})
      : _storage = storage ?? const FlutterSecureStorage(),
        _random = random ?? Random.secure();

  static const _identifierKey = 'flycomm.device.identifier';
  static const _secretKey = 'flycomm.device.secret';

  final FlutterSecureStorage _storage;
  final Random _random;

  Future<DeviceCredentials> loadOrCreate() async {
    final existingId = await _storage.read(key: _identifierKey);
    final existingSecret = await _storage.read(key: _secretKey);

    if (existingId != null && existingSecret != null) {
      return DeviceCredentials(identifier: existingId, secret: existingSecret);
    }

    final created = _generate();
    await _storage.write(key: _identifierKey, value: created.identifier);
    await _storage.write(key: _secretKey, value: created.secret);
    return created;
  }

  /// identifier: 'flycomm-' + 32 hex = 40 caracteres, dentro de 16–128.
  /// secret: 48 bytes em base64url = 64 caracteres, dentro de 32–72.
  ///
  /// O teto de 72 é o do bcrypt: acima disso o algoritmo trunca em silêncio e
  /// dois segredos diferentes viram o mesmo.
  DeviceCredentials _generate() {
    String hex(int bytes) => List.generate(
          bytes,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();

    final secretBytes = List<int>.generate(48, (_) => _random.nextInt(256));

    return DeviceCredentials(
      identifier: 'flycomm-${hex(16)}',
      secret: base64Url.encode(secretBytes),
    );
  }
}
