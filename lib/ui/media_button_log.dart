import 'package:flutter/material.dart';

import '../audio/cues.dart';
import '../audio/media_buttons.dart';

/// O diagnóstico: tudo que o sistema mandou, cru e na ordem em que chegou.
///
/// Existe para responder uma pergunta que nenhuma documentação responde —
/// **o que este fone emite em cada gesto** —, e some quando ela estiver
/// respondida.
class MediaButtonLog extends StatelessWidget {
  const MediaButtonLog({super.key, required this.handler, this.cues});

  final MediaButtonHandler? handler;

  /// Só para mostrar a latência de saída medida. O número decide quanto o
  /// aviso sonoro precisa esperar antes de abrir o microfone, e chutá-lo seria
  /// voltar a inventar constante.
  final ToneCues? cues;

  @override
  Widget build(BuildContext context) {
    final handler = this.handler;
    final text = Theme.of(context).textTheme;

    if (handler == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'A sessão de mídia só está montada no iPhone nesta fatia. '
          'No Android nenhum gesto chega, e é de propósito.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return StreamBuilder<MediaCommand>(
      stream: handler.commands,
      builder: (context, _) {
        final rows = handler.log;

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Comandos de mídia recebidos', style: text.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Faça um gesto de cada vez no fone e veja o que aparece. '
                'Nada aqui significa que o gesto não sai do fone, ou que outro '
                'app tomou o Now Playing.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Latência de saída medida: '
                '${cues == null ? '—' : '${cues!.latency.inMilliseconds} ms'}'
                ' (atualiza a cada PTT)',
                style: text.bodySmall,
              ),
              const Divider(height: 24),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: Text('Nada chegou ainda.')),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Text(
                            _time(rows[index].at),
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            rows[index].name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Com milissegundos de propósito: dois comandos do mesmo gesto chegam a
/// dezenas de milissegundos um do outro, e é isso que distingue "o fone mandou
/// dois" de "eu toquei duas vezes".
String _time(DateTime at) => '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}:'
    '${at.second.toString().padLeft(2, '0')}.'
    '${at.millisecond.toString().padLeft(3, '0')}';
