import 'package:flycomm/env.dart';

/// Credenciais semeadas pelo servidor. Cada uma vira um token novo e revoga o
/// anterior daquele dispositivo, então dois testes concorrentes não podem
/// compartilhar o mesmo identifier.
const seededDevices = <String, ({String identifier, String secret, String name})>{
  'rodrigo': (
    identifier: 'demo-device-rodrigo-0001',
    secret: 'demo-secret-rodrigo-000000000000000000',
    name: 'Rodrigo',
  ),
  'marina': (
    identifier: 'demo-device-marina-0002',
    secret: 'demo-secret-marina-0000000000000000000',
    name: 'Marina',
  ),
  'tiago': (
    identifier: 'demo-device-tiago-0003',
    secret: 'demo-secret-tiago-00000000000000000000',
    name: 'Tiago',
  ),
};

const seededInviteCodes = ['FLY-TEST', 'FLY-2FLY'];

String get httpBase {
  Env.assertConfigured();
  return Env.httpBase;
}
