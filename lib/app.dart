import 'package:flutter/material.dart';

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
import 'room/room_repository.dart';
import 'room/server_clock.dart';
import 'ui/app_scope.dart';
import 'ui/rooms_screen.dart';

final _theme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B4965)),
  useMaterial3: true,
);

class FlycommApp extends StatelessWidget {
  const FlycommApp({super.key});

  // Sem MaterialApp aqui: ele precisa ficar ABAIXO do AppScope, senão as telas
  // empurradas no Navigator não enxergam o escopo (ver _Shell).
  @override
  Widget build(BuildContext context) => const _Bootstrap();
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
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<AppScope> _ready = _start();

  /// A ordem importa: GET /config antes de tudo, porque é dele que saem os
  /// orçamentos, e ele sincroniza o relógio de saída.
  Future<AppScope> _start() async {
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

    return AppScope(
      api: api,
      clock: clock,
      config: config,
      auth: auth,
      rooms: RoomRepository(api: api),
      catchup: CatchupRepository(api: api, clock: clock),
      messageApi: MessageApi(api: api),
      history: HistoryRepository(db),
      audioStore: await AudioStore.open(),
      userId: user.id,
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
                child: Center(
                  child: Text(
                    'Não deu para falar com o servidor.\n\n${snapshot.error}',
                    textAlign: TextAlign.center,
                  ),
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
