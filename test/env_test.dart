import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/env.dart';

void main() {
  group('Env.tlsFor', () {
    test('https vira wss', () {
      expect(Env.tlsFor('https://flycomm.medeirostec.com.br'), isTrue);
    });

    test('http vira ws', () {
      expect(Env.tlsFor('http://192.168.0.10:8000'), isFalse);
    });
  });
}
