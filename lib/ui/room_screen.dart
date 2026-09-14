import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../audio/cues.dart';
import '../audio/flight_session.dart';
import '../audio/gesture_ptt.dart';
import '../audio/media_buttons.dart';
import '../audio/player.dart';
import '../audio/recorder.dart';
import '../history/database.dart';
import '../room/models.dart';
import '../room/reverb_client.dart';
import '../room/room_session.dart';
import '../env.dart';
import 'app_scope.dart';
import 'media_button_log.dart';
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
  FlightSession? _flight;
  GesturePtt? _gesture;
  ToneCues? _cues;
  StreamSubscription<MediaCommand>? _commands;
  String? _error;
  bool _micGranted = false;
  bool _inFlight = false;
  bool _gestureOpen = false;
  String? _lastProblem;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session == null) _open();
  }

  Future<void> _open() async {
    final scope = AppScope.of(context);

    _micGranted = await Permission.microphone.request().isGranted;

    // Preparado agora, e não no primeiro PTT: montar o tom custa dezenas de
    // milissegundos, e pagá-los no aperto atrasaria o aviso de "pode falar".
    final cues = ToneCues()..prepare();

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
      uploader: scope.uploader,
      recorder: PttRecorder(
        segmentMax: scope.budgets.segmentMax,
        serverNow: scope.clock.now,
      ),
      player: SegmentPlayer(),
      cues: cues,
    );

    _cues = cues;

    // Banner e não SnackBar: a falha que mais importa acontece com a tela
    // apagada, e um aviso passageiro morre antes de alguém ver. Este fica até
    // ser dispensado.
    session.playbackProblems.listen((problem) {
      if (mounted) setState(() => _lastProblem = problem);
    });

    session.gaps.listen((windowStart) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Houve um trecho que não deu para recuperar.'),
      ));
    });

    session.roomChanges.listen((_) {
      if (mounted) setState(() {});
    });

    final flight = FlightSession(onInterrupted: session.stopPlayback);
    flight.changes.listen((value) {
      if (mounted) setState(() => _inFlight = value);
    });

    _listenToTheHeadset(scope, session);

    try {
      await session.open();
      if (!mounted) return;
      setState(() {
        _session = session;
        _flight = flight;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  /// O gesto no fone aciona o **mesmo** PTT do botão da tela: segmentador,
  /// upload, histórico, tudo igual. Nada de caminho paralelo — um caminho
  /// paralelo provaria que o gesto chega, e não que a mensagem sai.
  void _listenToTheHeadset(AppScope scope, RoomSession session) {
    final gesture = GesturePtt(
      start: session.pressPtt,
      stop: session.releasePtt,
      // Do servidor, não daqui: é o mesmo teto que corta o segmento.
      ceiling: scope.budgets.segmentMax,
    );
    gesture.changes.listen((open) {
      if (mounted) setState(() => _gestureOpen = open);
    });

    _commands = scope.mediaButtons.commands.listen((_) {
      // setState mesmo quando o gesto não vira gravação: o diagnóstico precisa
      // mostrar o comando que o antirrebote engoliu. É justamente ele que
      // distingue "o fone manda dois" de "eu toquei duas vezes".
      if (mounted) setState(() {});
      if (_micGranted) unawaited(gesture.handle());
    });

    _gesture = gesture;
  }

  void _showMediaButtonLog() {
    final buttons = AppScope.of(context).mediaButtons;
    final cues = _cues;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => MediaButtonLog(handler: buttons, cues: cues),
    );
  }

  @override
  void dispose() {
    _commands?.cancel();
    _gesture?.dispose();
    _cues?.dispose();
    _flight?.dispose();
    _session?.dispose();
    super.dispose();
  }

  /// Entrar em voo é explícito e feito com o app aberto (7.1 da spec): é o que
  /// mantém a escuta viva com a tela apagada, e o que diz ao piloto que o app
  /// assumiu o rádio.
  Future<void> _toggleFlight() async {
    final flight = _flight;
    if (flight == null) return;

    // Entrar em voo é a ação de que o piloto mais depende e a que ele menos
    // consegue conferir: ele liga, guarda o celular, e só descobre horas
    // depois. Falhar em silêncio aqui é o pior caso do app.
    try {
      if (flight.isInFlight) {
        await flight.leave();
      } else {
        await flight.enter();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _lastProblem = 'Não deu para entrar em voo: $error');
    }
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
          IconButton(
            onPressed: _showMediaButtonLog,
            icon: const Icon(Icons.headset_mic_outlined),
            tooltip: 'Comandos de mídia recebidos',
          ),
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
          if (_lastProblem != null)
            MaterialBanner(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              content: Text(_lastProblem!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _lastProblem = null),
                  child: const Text('Entendi'),
                ),
              ],
            ),
          Expanded(
            child: StreamBuilder<List<LocalMessage>>(
              stream: session.messages,
              builder: (context, snapshot) {
                final rows = snapshot.data ?? const <LocalMessage>[];
                if (rows.isEmpty) {
                  return const Center(child: Text('Nada dito ainda.'));
                }
                // De trás para frente: o índice 0 — a fala mais nova — fica
                // embaixo, e a rolagem nasce colada nele. É o que dá o
                // autoscroll de graça, sem ScrollController e sem o salto que
                // um `jumpTo` no fim da lista produz. Quem rolou para cima
                // para reler algo fica onde estava, que é o certo.
                return ListView.separated(
                  reverse: true,
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
          if (_gestureOpen) const _GestureBar(),
          _FlightBar(inFlight: _inFlight, onToggle: _toggleFlight),
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

/// O controle de entrar em voo.
///
/// Deliberadamente barulhento quando ligado: é o estado em que o app continua
/// ouvindo com a tela apagada e consumindo bateria, e o piloto precisa saber
/// que está nele. Um interruptor discreto seria pior, não melhor.
class _FlightBar extends StatelessWidget {
  const _FlightBar({required this.inFlight, required this.onToggle});

  final bool inFlight;
  final Future<void> Function() onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Material(
      color: inFlight ? colors.tertiaryContainer : colors.surfaceContainerHighest,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                inFlight ? Icons.flight : Icons.flight_takeoff,
                color: inFlight ? colors.onTertiaryContainer : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      inFlight ? 'EM VOO' : 'Entrar em voo',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: inFlight
                            ? colors.onTertiaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      inFlight
                          ? 'Continua ouvindo com a tela apagada'
                          : 'Com a tela apagada, você para de receber',
                      style: TextStyle(
                        fontSize: 12,
                        color: inFlight
                            ? colors.onTertiaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(value: inFlight, onChanged: (_) => onToggle()),
            ],
          ),
        ),
      ),
    );
  }
}

/// O microfone foi aberto pelo fone, não pelo dedo.
///
/// Precisa existir porque o botão da tela não muda de cor nesse caso: quem
/// está gravando é outro caminho, e sem este aviso o piloto fala achando que
/// não está gravando, ou pior, não fala achando que está.
class _GestureBar extends StatelessWidget {
  const _GestureBar();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: colors.error,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.headset_mic, color: colors.onError, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'GRAVANDO PELO GESTO — fecha em 5 s, ou no próximo toque',
              style: TextStyle(
                color: colors.onError,
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
