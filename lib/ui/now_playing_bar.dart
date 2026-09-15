import 'package:flutter/material.dart';

import '../history/database.dart';
import '../room/room_session.dart';
import 'message_tile.dart';

/// Quem está falando no alto-falante agora.
///
/// A linha do histórico correspondente também fica destacada, e isso sozinho
/// não basta: a lista rola, e uma fala recuperada pelo catch-up entra na
/// posição em que foi **gravada**, que pode estar bem acima do que está na
/// tela. Esta barra fica sempre no mesmo lugar, encostada no PTT, e responde a
/// pergunta sem o piloto ter que procurar.
///
/// Some inteira no silêncio, de propósito: uma barra permanente dizendo "nada
/// tocando" vira moldura e para de ser lida.
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key, required this.session, required this.me});

  final RoomSession session;

  /// Para dizer "Você" em vez do próprio nome, como o histórico já faz.
  final int me;

  @override
  Widget build(BuildContext context) => StreamBuilder<String?>(
        stream: session.nowPlaying,
        // O valor atual, e não só o stream: quem assina depois de a reprodução
        // já ter começado ficaria sem nada e desenharia silêncio por cima de
        // uma fala em andamento.
        initialData: session.nowPlayingId,
        builder: (context, playing) {
          final id = playing.data;
          if (id == null) return const SizedBox.shrink();

          return StreamBuilder<List<LocalMessage>>(
            stream: session.messages,
            builder: (context, snapshot) => _Bar(
              message: _find(snapshot.data, id),
              me: me,
            ),
          );
        },
      );

  /// A mensagem que está tocando, se o histórico já a entregou. Nulo é um
  /// estado real e curto — a fala toca no instante em que entra no banco, e a
  /// barra precisa dizer que há som mesmo sem saber ainda de quem.
  static LocalMessage? _find(List<LocalMessage>? rows, String id) {
    for (final row in rows ?? const <LocalMessage>[]) {
      if (row.id == id) return row;
    }
    return null;
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.message, required this.me});

  final LocalMessage? message;
  final int me;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final who = switch (message) {
      null => 'alguém',
      final m when m.direction == MessageDirection.outgoing || m.authorId == me =>
        'Você',
      final m => m.authorName ?? (m.origin == 'radio' ? 'Rádio' : 'sem nome'),
    };

    final when = message == null ? '' : ' · ${clockOf(message!.recordedAt)}';

    return Container(
      width: double.infinity,
      color: colors.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.volume_up, color: colors.onPrimaryContainer, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'TOCANDO — $who$when',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.onPrimaryContainer,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
