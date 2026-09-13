import 'package:flutter/material.dart';

import '../history/database.dart';

/// Uma linha do histórico.
///
/// O estado é a informação mais importante da tela: **não entregue** significa
/// que ninguém ouviu o piloto, e ele precisa saber disso para pegar o rádio.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isMine,
    required this.onPlay,
  });

  final LocalMessage message;
  final bool isMine;
  final Future<void> Function() onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final seconds = (message.durationMs / 1000).toStringAsFixed(1);

    final (label, color, icon) = switch (message.state) {
      MessageState.recorded => ('gravada', colors.outline, Icons.fiber_manual_record),
      MessageState.sending => ('enviando…', colors.outline, Icons.upload),
      MessageState.delivered => ('entregue', colors.primary, Icons.check),
      MessageState.undelivered =>
        ('NÃO ENTREGUE — ninguém ouviu', colors.error, Icons.error_outline),
      MessageState.received => ('', colors.primary, Icons.volume_up),
      MessageState.late =>
        ('atrasada — toque para ouvir', colors.tertiary, Icons.history),
    };

    final author = isMine
        ? 'Você'
        : message.authorName ?? (message.origin == 'radio' ? 'Rádio' : 'sem nome');

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text('$author · $seconds s'),
      subtitle: label.isEmpty
          ? Text('segmento ${message.segmentIndex + 1}')
          : Text(label, style: TextStyle(color: color)),
      trailing: message.audioPath == null
          ? const Icon(Icons.cloud_off)
          : IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: onPlay,
              tooltip: 'Ouvir',
            ),
    );
  }
}
