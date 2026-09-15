import 'package:flutter/material.dart';

import '../history/database.dart';

/// A hora local, com segundos.
///
/// Segundos e não só hora:minuto porque numa sala de rádio as falas vêm em
/// rajadas de poucos segundos, e "12:04" repetido em cinco linhas seguidas não
/// diz nada sobre a ordem nem sobre o intervalo entre elas.
///
/// É o horário **da fala**, não o da chegada: `recordedAt` é `captured_at`, e é
/// por isso que uma mensagem atrasada aparece encaixada onde foi gravada. Se
/// mostrasse a chegada, a linha contaria uma hora e a posição na lista contaria
/// outra.
String clockOf(DateTime moment) {
  final local = moment.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');

  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// Uma linha do histórico.
///
/// O estado é a informação mais importante da tela: **não entregue** significa
/// que ninguém ouviu o piloto, e ele precisa saber disso para pegar o rádio.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isMine,
    required this.isPlaying,
    required this.onPlay,
  });

  final LocalMessage message;
  final bool isMine;

  /// Esta é a fala que está saindo pelo alto-falante agora.
  ///
  /// A fila toca uma voz por vez e a tela não dizia qual: o piloto ouvia
  /// alguém falando sem saber de quem era, nem em que linha voltar depois.
  final bool isPlaying;
  final Future<void> Function() onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final seconds = (message.durationMs / 1000).toStringAsFixed(1);

    final (label, color, icon) = switch (message.state) {
      MessageState.recorded => ('gravada', colors.outline, Icons.fiber_manual_record),
      MessageState.sending => ('enviando…', colors.outline, Icons.upload),
      MessageState.delivered => ('entregue', colors.primary, Icons.check),
      // Entrou no histórico dos outros, mas depois do prazo: ninguém ouviu ao
      // vivo. Vai em cor de alerta porque a consequência prática é a mesma da
      // não entregue — pegue o rádio.
      MessageState.deliveredLate => (
          'entregue atrasada — ninguém ouviu ao vivo',
          colors.error,
          Icons.running_with_errors,
        ),
      MessageState.undelivered =>
        ('NÃO ENTREGUE — ninguém ouviu', colors.error, Icons.error_outline),
      MessageState.received => ('', colors.primary, Icons.volume_up),
      MessageState.late =>
        ('atrasada — toque para ouvir', colors.tertiary, Icons.history),
    };

    final author = isMine
        ? 'Você'
        : message.authorName ?? (message.origin == 'radio' ? 'Rádio' : 'sem nome');

    final hasAudio = message.audioPath != null;

    // "Já ouvi isto?" só faz sentido sobre a fala dos outros: a própria o
    // piloto acabou de dizer, e a marca ali só competiria com o estado de
    // entrega, que é o que importa na linha dele.
    final heard = isMine
        ? null
        : message.played
            ? ('ouvida', colors.outline, Icons.done_all)
            : ('NÃO OUVIDA', colors.tertiary, Icons.hearing_disabled);

    final detail = [clockOf(message.recordedAt), if (label.isNotEmpty) label]
        .join(' · ');

    // Tocando agora: a marca é do **card inteiro** — fundo, ícone de origem,
    // título e o botão de play, que deixa de ser um convite e vira um estado.
    // A pergunta do piloto é "qual destes está tocando?", e uma linha separada
    // em outro canto da tela não responde isso: obriga a comparar dois lugares.
    final speaking = colors.onPrimaryContainer;

    // `graphic_eq` e não `pause`: tocar de novo recomeça a fala, não retoma.
    // Um ícone de pausa prometeria um controle que não existe.
    final trailingIcon = isPlaying
        ? Icons.graphic_eq
        : (hasAudio ? Icons.play_arrow : Icons.cloud_off);

    // A linha inteira toca, não só o ícone: a spec diz "ouvível por toque", e
    // um alvo de 24 px é inoperável com luva, em voo.
    return ListTile(
      onTap: onPlay,
      tileColor: isPlaying ? colors.primaryContainer : null,
      leading: Icon(
        isPlaying ? Icons.volume_up : icon,
        color: isPlaying ? speaking : color,
      ),
      title: Text(
        '$author · $seconds s',
        style: TextStyle(
          color: isPlaying ? speaking : null,
          fontWeight: isPlaying ? FontWeight.bold : null,
        ),
      ),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              detail,
              style: TextStyle(
                color: isPlaying ? speaking : (label.isEmpty ? null : color),
              ),
            ),
          ),
          if (heard != null) ...[
            const SizedBox(width: 8),
            Icon(heard.$3, size: 14, color: isPlaying ? speaking : heard.$2),
            const SizedBox(width: 4),
            Text(
              heard.$1,
              style: TextStyle(
                fontSize: 12,
                color: isPlaying ? speaking : heard.$2,
              ),
            ),
          ],
        ],
      ),
      trailing: Icon(
        trailingIcon,
        color: isPlaying ? speaking : (hasAudio ? null : colors.outline),
      ),
    );
  }
}
