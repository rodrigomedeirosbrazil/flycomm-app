import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/models.dart';
import 'package:flycomm/room/roster.dart';

void main() {
  Member pilot(int id, String name) =>
      Member(id: id, displayName: name, role: 'member');

  group('Roster.from', () {
    test('separa quem está ouvindo de quem está fora', () {
      final roster = Roster.from(
        known: [pilot(1, 'Ana'), pilot(2, 'Bruno'), pilot(3, 'Célia')],
        present: [pilot(1, 'Ana'), pilot(3, 'Célia')],
        connected: true,
        me: 1,
      );

      expect(roster.listening, 2);
      expect(roster.total, 3);
      expect(roster.certain, isTrue);
      expect(
        roster.entries.map((e) => (e.displayName, e.presence)),
        [
          ('Ana', PilotPresence.listening),
          ('Célia', PilotPresence.listening),
          ('Bruno', PilotPresence.away),
        ],
      );
    });

    test('marca quem sou eu', () {
      final roster = Roster.from(
        known: [pilot(1, 'Ana'), pilot(2, 'Bruno')],
        present: [pilot(1, 'Ana'), pilot(2, 'Bruno')],
        connected: true,
        me: 2,
      );

      expect(roster.entries.singleWhere((e) => e.isMe).id, 2);
    });

    test('inclui quem está na presença e não no quadro', () {
      // Não existe evento de entrada na sala: room.updated carrega só
      // {id, name, frequency_hz}. Sem a união, quem entra enquanto você está
      // dentro aparece na presença e some da lista.
      final roster = Roster.from(
        known: [pilot(1, 'Ana')],
        present: [pilot(1, 'Ana'), pilot(9, 'Zeca')],
        connected: true,
        me: 1,
      );

      expect(roster.total, 2);
      expect(roster.entries.map((e) => e.displayName), ['Ana', 'Zeca']);
    });

    test('com o socket caído não afirma nada sobre ninguém', () {
      // Numa queda o ReverbClient NÃO limpa os membros — só o disconnect()
      // explícito limpa. Então o perigo não é lista vazia, é lista confiante e
      // errada: oito nomes em verde no exato momento em que o app não faz
      // ideia de quem está lá.
      final roster = Roster.from(
        known: [pilot(1, 'Ana'), pilot(2, 'Bruno')],
        present: [pilot(1, 'Ana'), pilot(2, 'Bruno')],
        connected: false,
        me: 1,
      );

      expect(roster.certain, isFalse);
      expect(roster.listening, 0);
      expect(roster.total, 2);
      expect(
        roster.entries.every((e) => e.presence == PilotPresence.unknown),
        isTrue,
      );
    });

    test('ordena por nome dentro de cada grupo, sem depender de maiúscula', () {
      // 'Zeca' e 'ana' de propósito: por código UTF-16 'Z' (0x5A) vem antes de
      // 'a' (0x61), então a ordenação ingênua poria Zeca na frente. Com
      // ['zeca', 'Ana', 'bruno'] — o fixture anterior — os dois critérios dão o
      // mesmo resultado, e o teste passaria mesmo sem o toLowerCase.
      final roster = Roster.from(
        known: [pilot(1, 'Zeca'), pilot(2, 'ana'), pilot(3, 'bruno')],
        present: [pilot(1, 'Zeca'), pilot(2, 'ana'), pilot(3, 'bruno')],
        connected: true,
        me: 2,
      );

      expect(roster.entries.map((e) => e.displayName),
          ['ana', 'bruno', 'Zeca']);
    });
  });
}
