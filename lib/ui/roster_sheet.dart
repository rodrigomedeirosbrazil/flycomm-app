import 'package:flutter/material.dart';

import '../room/reverb_client.dart';
import '../room/room_session.dart';
import '../room/roster.dart';

/// A barra de presença, que é também a porta.
///
/// Sem gaveta: uma `endDrawer` precisa ou de swipe da borda — que disputa com
/// o gesto de voltar nas duas plataformas — ou de um ícone de 24 px na AppBar.
/// Esta barra já existia, é de largura inteira e já teria que virar tocável
/// para resolver o corte dos nomes. Uma afordância em vez de duas, e um alvo
/// operável de luva.
class PresenceBar extends StatelessWidget {
  const PresenceBar({super.key, required this.session, required this.me});

  final RoomSession session;
  final int me;

  @override
  Widget build(BuildContext context) => StreamBuilder<ReverbConnection>(
        stream: session.connectionState,
        initialData: session.connectionNow,
        builder: (context, connection) => StreamBuilder<RoomPresence>(
          stream: session.presence,
          initialData: session.presenceNow,
          builder: (context, presence) {
            final roster = Roster.from(
              known: session.current.members,
              present: presence.data?.members ?? const [],
              connected: connection.data == ReverbConnection.connected,
              me: me,
            );

            return _Bar(
              roster: roster,
              onTap: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (_) => RosterSheet(roster: roster),
              ),
            );
          },
        ),
      );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.roster, required this.onTap});

  final Roster roster;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;

    final names = roster.entries
        .where((e) => e.presence == PilotPresence.listening)
        .map((e) => e.isMe ? 'você' : e.displayName)
        .join(', ');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 16, right: 16),
        child: Row(
          children: [
            Icon(
              Icons.circle,
              size: 9,
              color: roster.certain ? colors.primary : colors.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                roster.certain
                    ? '${roster.listening} de ${roster.total} ouvindo'
                        '${names.isEmpty ? '' : ' · $names'}'
                    : 'Reconectando…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: small,
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: colors.outline),
          ],
        ),
      ),
    );
  }
}

/// Quem está ouvindo, em dois grupos.
class RosterSheet extends StatelessWidget {
  const RosterSheet({super.key, required this.roster});

  final Roster roster;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text(
            roster.certain
                ? '${roster.listening} de ${roster.total} ouvindo agora'
                : 'Reconectando',
            style: text.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            roster.certain
                // Um Android com a tela apagada cai da presença de propósito:
                // sem Foreground Service — Fase 4 — ele realmente para de
                // receber. O indicador vai estar certo quando parecer errado.
                ? 'Quem está fora não ouve a sua fala ao vivo. Um celular com '
                    'a tela apagada pode sair daqui e continuar na sala.'
                : 'Não dá para saber quem está ouvindo enquanto a sua conexão '
                    'não volta.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final entry in roster.entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                switch (entry.presence) {
                  PilotPresence.listening => Icons.hearing,
                  PilotPresence.away => Icons.hearing_disabled,
                  PilotPresence.unknown => Icons.help_outline,
                },
                color: switch (entry.presence) {
                  PilotPresence.listening => colors.primary,
                  PilotPresence.away => colors.outline,
                  PilotPresence.unknown => colors.outline,
                },
              ),
              title: Text(entry.isMe
                  ? '${entry.displayName} (você)'
                  : entry.displayName),
              trailing: Text(
                switch (entry.presence) {
                  PilotPresence.listening => 'ouvindo',
                  PilotPresence.away => 'fora',
                  PilotPresence.unknown => '',
                },
                style: TextStyle(
                  color: entry.presence == PilotPresence.listening
                      ? colors.primary
                      : colors.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
