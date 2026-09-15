import 'package:flutter/material.dart';

import '../env.dart';
import 'app_scope.dart';
import 'media_button_log.dart';

/// A configuração do piloto.
///
/// Existe por um motivo só, e é o nome: até aqui ele era sorteado no primeiro
/// arranque — `Piloto a3f2` — e permanente, porque o servidor ignora
/// `display_name` na recuperação. Quem o muda é `PATCH /me`, que estava
/// implementado e nunca era chamado.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  bool _seeded = false;
  bool _saving = false;
  bool _saved = false;
  String? _problem;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _controller.text = AppScope.of(context).user.value.displayName;
    _seeded = true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 1–60 é o limite do contrato (§6.2.1 da spec da Fase 2). Validar aqui não
  /// é zelo: descobrir por um 422 é uma ida ao servidor para aprender uma
  /// constante que já está escrita, e em rede de campo essa ida custa segundos
  /// com o piloto olhando para um botão que não responde.
  Future<void> _save() async {
    final scope = AppScope.of(context);
    final name = _controller.text.trim();

    if (name.isEmpty || name.length > 60) {
      setState(() => _problem = 'O nome tem de 1 a 60 caracteres.');
      return;
    }

    setState(() {
      _saving = true;
      _saved = false;
      _problem = null;
    });

    try {
      scope.user.value = await scope.auth.updateDisplayName(name);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _problem = 'Não deu para salvar: $error';
      });
    }
  }

  /// Os orçamentos vêm de GET /config e nunca de constante no código. Quando
  /// uma fala é descartada por vencida, o prazo que a descartou não está em
  /// nenhum outro lugar da interface.
  static String _budget(Duration value) {
    final seconds = value.inMilliseconds / 1000;
    if (seconds >= 60) return '${(seconds / 60).toStringAsFixed(0)} min';
    return '${seconds.toStringAsFixed(seconds % 1 == 0 ? 0 : 1)} s';
  }

  void _showMediaButtonLog() {
    final buttons = AppScope.of(context).mediaButtons;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Sem `cues`: a latência de saída medida só existe onde o tom foi
      // montado, que é a tela da sala. O log dos comandos, que é a pergunta
      // que importa aqui, não depende dela.
      builder: (context) => MediaButtonLog(handler: buttons),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Configuração')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Você', style: text.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            textCapitalization: TextCapitalization.words,
            maxLength: 60,
            // Salvar é explícito, e não ao perder o foco: um campo que aceita
            // a digitação e não diz se gravou é pior que um campo que não
            // existe, porque o piloto vai embora achando que trocou.
            onChanged: (_) {
              if (_saved || _problem != null) {
                setState(() {
                  _saved = false;
                  _problem = null;
                });
              }
            },
            decoration: const InputDecoration(
              labelText: 'Nome',
              helperText: 'É este nome que os outros pilotos veem na sala e no '
                  'histórico.',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Salvar'),
              ),
              const SizedBox(width: 12),
              if (_saved)
                Row(children: [
                  Icon(Icons.check, size: 18, color: colors.primary),
                  const SizedBox(width: 4),
                  Text('Salvo', style: TextStyle(color: colors.primary)),
                ]),
              if (_problem != null)
                Expanded(
                  child: Text(
                    _problem!,
                    style: TextStyle(color: colors.error),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),
          Text('Diagnóstico', style: text.titleMedium),
          const SizedBox(height: 12),
          _Row('Servidor', Env.httpBase),
          _Row(
            'Relógio',
            AppScope.of(context).clock.isSynced
                ? 'sincronizado, desvio de '
                    '${AppScope.of(context).clock.skew.inMilliseconds} ms'
                : 'ainda não sincronizado',
          ),
          const SizedBox(height: 12),
          Text('Orçamentos de tempo', style: text.labelLarge),
          const SizedBox(height: 4),
          _Row('Toca sozinho até', _budget(AppScope.of(context).budgets.playbackDeadline)),
          _Row('Insiste em subir até', _budget(AppScope.of(context).budgets.deliveryDeadline)),
          _Row('Segmento', _budget(AppScope.of(context).budgets.segmentMax)),
          _Row('Recuperação olha', _budget(AppScope.of(context).budgets.catchupWindow)),
          _Row('Áudio vive no servidor', _budget(AppScope.of(context).budgets.blobTtl)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _showMediaButtonLog,
            icon: const Icon(Icons.headset_mic_outlined),
            label: const Text('Comandos de mídia recebidos'),
          ),
        ],
      ),
    );
  }
}

/// Rótulo à esquerda, valor à direita. Só diagnóstico usa.
class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(label)),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ],
        ),
      );
}
