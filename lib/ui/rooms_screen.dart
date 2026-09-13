import 'package:flutter/material.dart';

import '../room/models.dart';
import 'app_scope.dart';
import 'room_screen.dart';

class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key});

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  late Future<List<Room>> _rooms;

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

    if (code == null || code.isEmpty || !mounted) return;

    try {
      final room = await AppScope.of(context).rooms.join(code);
      if (!mounted) return;
      _reload();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RoomScreen(room: room)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Não deu para entrar: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Minhas salas')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _joinByCode,
          icon: const Icon(Icons.qr_code),
          label: const Text('Entrar por código'),
        ),
        body: FutureBuilder<List<Room>>(
          future: _rooms,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('Erro: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final rooms = snapshot.data!;
            if (rooms.isEmpty) {
              return const Center(
                child: Text('Nenhuma sala ainda.\nEntre por um código.',
                    textAlign: TextAlign.center),
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
                  );
                },
              ),
            );
          },
        ),
      );
}

/// A frequência é guardada como inteiro em Hz e só vira texto aqui.
/// Nula é um estado honesto: "ainda não combinamos a frequência".
String formatFrequency(int? hz) {
  if (hz == null) return 'sem frequência';
  return '${(hz / 1000000).toStringAsFixed(3)} MHz';
}
