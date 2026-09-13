import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../audio/player.dart';
import '../audio/recorder.dart';
import '../history/database.dart';
import '../room/models.dart';
import '../room/reverb_client.dart';
import '../room/room_session.dart';
import '../env.dart';
import 'app_scope.dart';
import 'message_tile.dart';
import 'ptt_button.dart';
import 'rooms_screen.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key, required this.room});

  final Room room;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  RoomSession? _session;
  String? _error;
  bool _micGranted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session == null) _open();
  }

  Future<void> _open() async {
    final scope = AppScope.of(context);

    _micGranted = await Permission.microphone.request().isGranted;

    final session = RoomSession(
      room: widget.room,
      budgets: scope.budgets,
      clock: scope.clock,
      reverb: ReverbClient(
        api: scope.api,
        appKey: Env.wsKey,
        host: Env.wsHost,
        port: Env.wsPort,
      ),
      catchup: scope.catchup,
      messageApi: scope.messageApi,
      history: scope.history,
      audioStore: scope.audioStore,
      recorder: PttRecorder(
        segmentMax: scope.budgets.segmentMax,
        serverNow: scope.clock.now,
      ),
      player: SegmentPlayer(),
    );

    session.gaps.listen((windowStart) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Houve um trecho que não deu para recuperar.'),
      ));
    });

    session.roomChanges.listen((_) {
      if (mounted) setState(() {});
    });

    try {
      await session.open();
      if (!mounted) return;
      setState(() => _session = session);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  Future<void> _editFrequency() async {
    final session = _session!;
    final scope = AppScope.of(context);
    final controller = TextEditingController(
      text: session.current.frequencyHz == null
          ? ''
          : (session.current.frequencyHz! / 1000000).toStringAsFixed(3),
    );

    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Frequência combinada'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [_FrequencyInput()],
          decoration: const InputDecoration(
            suffixText: 'MHz',
            hintText: '145,550',
            helperText: '145,550 ou 145550. Faixas: 136–174 e 400–470 MHz.\n'
                'Vazio limpa. Quem sintoniza o rádio é você.',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );

    if (value == null || !mounted) return;

    // Aceita 145,550 / 145.550 / 145550, porque o piloto está com pressa.
    final hz = value.isEmpty ? null : scope.config.frequencyHzFromInput(value);

    if (value.isNotEmpty && hz == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Não consegui ler isso como uma frequência das faixas do rádio '
          '(136–174 e 400–470 MHz). Tente 145,550 ou 145550.',
        ),
      ));
      return;
    }

    await scope.rooms.update(
      session.current.id,
      frequencyHz: hz,
      clearFrequency: hz == null,
    );
    // Não há setState aqui de propósito: a mudança volta por room.updated, e
    // é assim que ela chega em todo mundo sem recarregar.
  }

  /// Toca e, se não der, diz por quê. Silêncio sem explicação é
  /// indistinguível de app quebrado.
  Future<void> _play(RoomSession session, String messageId) async {
    final problem = await session.playFromHistory(messageId);

    if (problem == null || !mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(problem)));
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.room.name)),
        body: Center(child: Text('Não deu para abrir a sala.\n\n$_error')),
      );
    }

    final session = _session;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.room.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final scope = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(session.current.name),
        actions: [
          TextButton.icon(
            onPressed: _editFrequency,
            icon: const Icon(Icons.radio),
            label: Text(formatFrequency(session.current.frequencyHz)),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: StreamBuilder<RoomPresence>(
            stream: session.presence,
            builder: (context, snapshot) {
              final names = snapshot.data?.members
                      .map((m) => m.displayName)
                      .join(', ') ??
                  'conectando…';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 16, right: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Na sala: $names',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              );
            },
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<LocalMessage>>(
              stream: session.messages,
              builder: (context, snapshot) {
                final rows = snapshot.data ?? const <LocalMessage>[];
                if (rows.isEmpty) {
                  return const Center(child: Text('Nada dito ainda.'));
                }
                return ListView.separated(
                  reverse: false,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => MessageTile(
                    message: rows[index],
                    isMine: rows[index].direction == MessageDirection.outgoing ||
                        rows[index].authorId == scope.userId,
                    onPlay: () => _play(session, rows[index].id),
                  ),
                );
              },
            ),
          ),
          if (!_micGranted)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Sem permissão de microfone: você só ouve.'),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: PttButton(
              enabled: _micGranted,
              onPress: session.pressPtt,
              onRelease: session.releasePtt,
            ),
          ),
        ],
      ),
    );
  }
}

/// Seis dígitos bastam para qualquer frequência das faixas do rádio, escrita
/// como MHz com decimais (145,550) ou como kHz (145550). O que passa disso é
/// ignorado em vez de recusado: no ar, o piloto não vai ler mensagem de erro.
class _FrequencyInput extends TextInputFormatter {
  static final _allowed = RegExp(r'^[0-9]*[.,]?[0-9]*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue previous,
    TextEditingValue next,
  ) {
    if (!_allowed.hasMatch(next.text)) return previous;

    final digits = next.text.replaceAll(RegExp('[^0-9]'), '');

    return digits.length > 6 ? previous : next;
  }
}
