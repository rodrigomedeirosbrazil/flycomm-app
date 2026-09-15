import 'package:flutter/material.dart';

import 'audio/media_buttons.dart';
import 'audio/player.dart';
import 'env.dart';
import 'history/audio_store.dart';
import 'history/database.dart';
import 'history/history_repository.dart';
import 'room/api_client.dart';
import 'room/auth_repository.dart';
import 'room/catchup_repository.dart';
import 'room/config_repository.dart';
import 'room/device_identity.dart';
import 'room/message_api.dart';
import 'room/message_uploader.dart';
import 'room/room_repository.dart';
import 'room/server_clock.dart';
import 'ui/app_scope.dart';
import 'ui/rooms_screen.dart';

final _theme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B4965)),
  useMaterial3: true,
);

class FlycommApp extends StatelessWidget {
  const FlycommApp({super.key, required this.mediaButtons});

  /// A sessão de mídia, montada no `main` antes de tudo.
  final MediaButtonHandler mediaButtons;

  // Sem MaterialApp aqui: ele precisa ficar ABAIXO do AppScope, senão as telas
  // empurradas no Navigator não enxergam o escopo (ver _Shell).
  @override
  Widget build(BuildContext context) => _Bootstrap(mediaButtons: mediaButtons);
}

/// O MaterialApp propriamente dito, montado dentro do AppScope.
///
/// A ordem importa e é fácil errar: o Navigator vive dentro do MaterialApp, e
/// uma rota empurrada por ele é irmã do `home`, não filha. Com o AppScope no
/// `home`, a tela de salas o encontrava e a tela da sala não —
/// "AppScope não encontrado acima deste widget", só no aparelho.
class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'flycomm',
        theme: _theme,
        home: const RoomsScreen(),
      );
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap({required this.mediaButtons});

  final MediaButtonHandler mediaButtons;

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Future<AppScope> _ready = _start();

  /// A tela de erro precisa de saída. O caso comum não é rede ruim: é o iOS
  /// perguntando pela permissão de Rede Local no primeiro arranque — o
  /// GET /config falha enquanto o piloto ainda não tocou em Permitir, e sem
  /// isto a única saída seria matar o app e abrir de novo.
  void _retry() => setState(() => _ready = _start());

  /// A ordem importa: GET /config antes de tudo, porque é dele que saem os
  /// orçamentos, e ele sincroniza o relógio de saída.
  Future<AppScope> _start() async {
    await configureAudioSession();

    final api = ApiClient(baseUrl: Env.httpBase);
    final clock = ServerClock();

    final config = await ConfigRepository(api: api, clock: clock).fetch();

    final auth = AuthRepository(api: api);
    final credentials = await DeviceIdentity().loadOrCreate();
    final user = await auth.authenticate(
      credentials,
      displayName: 'Piloto ${credentials.identifier.substring(8, 12)}',
    );

    final db = HistoryDatabase();
    final history = HistoryRepository(db);
    final messageApi = MessageApi(api: api);

    return AppScope(
      api: api,
      clock: clock,
      config: config,
      auth: auth,
      rooms: RoomRepository(api: api),
      catchup: CatchupRepository(api: api, clock: clock),
      messageApi: messageApi,
      history: history,
      audioStore: await AudioStore.open(),
      mediaButtons: widget.mediaButtons,
      uploader: MessageUploader(
        clock: clock,
        budgets: config.budgets,
        history: history,
        publish: messageApi.publish,
      ),
      user: ValueNotifier(user),
      child: DatabaseHolder(db: db, child: const _Shell()),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppScope>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _plain(Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Não deu para falar com o servidor.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Se o iOS acabou de pedir permissão de Rede Local, '
                      'toque em Permitir e tente de novo.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar de novo'),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ));
          }
          if (!snapshot.hasData) {
            return _plain(
              const Scaffold(body: Center(child: CircularProgressIndicator())),
            );
          }
          return snapshot.data!;
        },
      );
}

/// Arranque e falha de arranque acontecem antes de existir um MaterialApp,
/// e um Scaffold sem Directionality nem tema explode.
Widget _plain(Widget child) => MaterialApp(
      title: 'flycomm',
      theme: _theme,
      home: child,
    );
