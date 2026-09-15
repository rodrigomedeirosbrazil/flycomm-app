import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../room/models.dart';
import 'app_scope.dart';
import 'frequency.dart';
import 'room_screen.dart';
import 'settings_screen.dart';

class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key});

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  late Future<List<Room>> _rooms;
  bool _joining = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rooms = AppScope.of(context).rooms.mine();
  }

  void _reload() => setState(() {
        _rooms = AppScope.of(context).rooms.mine();
      });

  Future<void> _joinByCode() async {
    final controller = TextEditingController();

    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Entrar por código'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            hintText: 'FLY-7K2M',
            helperText: 'Pode digitar sem hífen e em minúscula',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Entrar'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (code == null || code.isEmpty || !mounted) return;

    setState(() => _joining = true);

    try {
      final room = await AppScope.of(context).rooms.join(code);
      if (!mounted) return;
      setState(() => _joining = false);
      _reload();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RoomScreen(room: room)),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _joining = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Não deu para entrar: $error')));
    }
  }

  /// Cria e **abre** a sala criada, mesmo desfecho de entrar por código: quem
  /// acabou de criar quer o código de convite, que está lá dentro.
  Future<void> _createRoom() async {
    final scope = AppScope.of(context);
    final name = TextEditingController();
    final frequency = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nova sala'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nome da sala'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: frequency,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FrequencyInput()],
              decoration: const InputDecoration(
                labelText: 'Frequência (opcional)',
                suffixText: 'MHz',
                hintText: '145,550',
                helperText: 'Dá para combinar depois.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Criar'),
          ),
        ],
      ),
    );

    final chosen = name.text.trim();
    final rawFrequency = frequency.text.trim();
    name.dispose();
    frequency.dispose();

    if (confirmed != true || chosen.isEmpty || !mounted) return;

    final hz = rawFrequency.isEmpty
        ? null
        : scope.config.frequencyHzFromInput(rawFrequency);

    if (rawFrequency.isNotEmpty && hz == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Não consegui ler isso como uma frequência das faixas do rádio '
          '(136–174 e 400–470 MHz). Tente 145,550 ou 145550.',
        ),
      ));
      return;
    }

    try {
      final room = await scope.rooms.create(name: chosen, frequencyHz: hz);
      if (!mounted) return;
      _reload();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RoomScreen(room: room)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Não deu para criar: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Minhas salas'),
          actions: [
            IconButton(
              onPressed: _createRoom,
              icon: const Icon(Icons.add),
              tooltip: 'Nova sala',
            ),
            IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Configuração',
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _joining ? null : _joinByCode,
          icon: _joining
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.qr_code),
          label: const Text('Entrar por código'),
        ),
        body: FutureBuilder<List<Room>>(
          future: _rooms,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              // A tela de arranque falha pelo mesmo motivo e tem botão; esta
              // não tinha, e o piloto ficava sem saída a não ser matar o app.
              return _Refreshable(
                onRefresh: _reload,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Não deu para buscar suas salas.\n\n${snapshot.error}',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar de novo'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final rooms = snapshot.data!;
            if (rooms.isEmpty) {
              // Envolvido no refresh de propósito: alguém pode te adicionar a
              // uma sala enquanto você olha para esta frase.
              return _Refreshable(
                onRefresh: _reload,
                child: const Text(
                  'Nenhuma sala ainda.\nCrie uma no + ou entre por um código.',
                  textAlign: TextAlign.center,
                ),
              );
            }

            return RefreshIndicator(
              onRefresh: () async => _reload(),
              child: ListView.separated(
                itemCount: rooms.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final room = rooms[index];
                  return ListTile(
                    title: Text(room.name),
                    subtitle: Text(
                      '${room.members.length} piloto(s) · '
                      '${formatFrequency(room.frequencyHz)}',
                    ),
                    trailing: Text(room.inviteCode),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RoomScreen(room: room),
                      ),
                    ),
                    // O código é ditado em voz alta, às vezes pelo próprio
                    // rádio. Copiar tira o erro de transcrição do caminho.
                    onLongPress: () async {
                      await Clipboard.setData(
                          ClipboardData(text: room.inviteCode));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('${room.inviteCode} copiado'),
                      ));
                    },
                  );
                },
              ),
            );
          },
        ),
      );
}

/// Conteúdo centralizado que ainda assim aceita puxar para atualizar.
///
/// Um `Center` não rola, e `RefreshIndicator` só dispara sobre um scrollable
/// que aceita overscroll — daí o `AlwaysScrollableScrollPhysics` e a altura
/// forçada pelo `ConstrainedBox`.
class _Refreshable extends StatelessWidget {
  const _Refreshable({required this.onRefresh, required this.child});

  final VoidCallback onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () async => onRefresh(),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
}
