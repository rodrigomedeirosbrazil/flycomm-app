import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/ui/message_tile.dart';

void main() {
  group('clockOf', () {
    test('mostra hora, minuto e segundo com dois dígitos', () {
      expect(clockOf(DateTime(2026, 9, 13, 9, 4, 7)), '09:04:07');
    });

    test('converte para a hora local do piloto', () {
      // Os carimbos vêm em UTC do servidor. Mostrar UTC daria uma hora que não
      // bate com o relógio de pulso de ninguém na sala.
      final utc = DateTime.utc(2026, 9, 13, 16, 30, 5);

      expect(clockOf(utc), clockOf(utc.toLocal()));
    });
  });
}
