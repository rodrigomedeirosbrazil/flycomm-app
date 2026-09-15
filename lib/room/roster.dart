import 'models.dart';

/// O que o piloto precisa saber sobre outro piloto, e é uma coisa só: ele te
/// ouve **agora**? Não é estado social — quem não está na presença não recebe
/// a sua fala ao vivo, e a resposta certa para ele é o rádio.
enum PilotPresence { listening, away, unknown }

class RosterEntry {
  const RosterEntry({
    required this.id,
    required this.displayName,
    required this.presence,
    required this.isMe,
  });

  final int id;
  final String displayName;
  final PilotPresence presence;
  final bool isMe;
}

/// Cruza o **quadro** da sala (quem entrou, da resposta HTTP) com a
/// **presença** (quem está conectado agora, do canal) e o estado do meu
/// próprio socket.
class Roster {
  const Roster({
    required this.entries,
    required this.listening,
    required this.total,
    required this.certain,
  });

  final List<RosterEntry> entries;
  final int listening;
  final int total;

  /// `false` quando o meu socket está caído. A interface tem que checar isto
  /// **antes** de `listening`: numa queda o cliente não limpa os membros, então
  /// a lista não fica vazia, fica velha.
  final bool certain;

  static Roster from({
    required List<Member> known,
    required List<Member> present,
    required bool connected,
    required int me,
  }) {
    final presentIds = {for (final member in present) member.id};

    // A união, e não só o quadro: não existe evento de entrada na sala, então
    // quem entra enquanto você está dentro só aparece pela presença. O nome
    // vem do lado presente quando há um, por ser o aperto de mão mais recente
    // com o servidor.
    final merged = <int, Member>{
      for (final member in known) member.id: member,
      for (final member in present) member.id: member,
    };

    final entries = merged.values
        .map((member) => RosterEntry(
              id: member.id,
              displayName: member.displayName,
              presence: !connected
                  ? PilotPresence.unknown
                  : presentIds.contains(member.id)
                      ? PilotPresence.listening
                      : PilotPresence.away,
              isMe: member.id == me,
            ))
        .toList();

    // Ouvindo em cima, e dentro de cada grupo por nome. `toLowerCase` porque
    // o piloto escolhe o próprio nome e ninguém combina maiúscula.
    entries.sort((a, b) {
      final byGroup = a.presence.index.compareTo(b.presence.index);
      if (byGroup != 0) return byGroup;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });

    return Roster(
      entries: entries,
      listening: connected ? presentIds.length : 0,
      total: merged.length,
      certain: connected,
    );
  }
}
