import 'package:flutter/widgets.dart';

import '../audio/media_buttons.dart';
import '../history/audio_store.dart';
import '../history/database.dart';
import '../history/history_repository.dart';
import '../room/api_client.dart';
import '../room/auth_repository.dart';
import '../room/budgets.dart';
import '../room/catchup_repository.dart';
import '../room/message_api.dart';
import '../room/message_uploader.dart';
import '../room/room_repository.dart';
import '../room/server_clock.dart';

/// Tudo que vive enquanto o app vive. Um InheritedWidget basta: não há estado
/// global mutável aqui, só as dependências já construídas.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.api,
    required this.clock,
    required this.config,
    required this.auth,
    required this.rooms,
    required this.catchup,
    required this.messageApi,
    required this.history,
    required this.audioStore,
    required this.mediaButtons,
    required this.uploader,
    required this.user,
    required super.child,
  });

  final ApiClient api;
  final ServerClock clock;
  final ServerConfig config;
  final AuthRepository auth;
  final RoomRepository rooms;
  final CatchupRepository catchup;
  final MessageApi messageApi;
  final HistoryRepository history;
  final AudioStore audioStore;

  /// Quem recebe o gesto do fone, nas duas plataformas.
  final MediaButtonHandler mediaButtons;

  /// Mora aqui, e não na sessão de sala, porque a insistência do upload dura
  /// minutos e precisa atravessar o piloto sair da tela. Continua sendo fila em
  /// memória, que morre com o processo: não é fila de saída persistente.
  final MessageUploader uploader;

  /// Quem é o piloto. Muda num lugar só — a tela de configuração — e é lido em
  /// outro, que é exatamente o caso para o qual o Flutter oferece
  /// `ValueNotifier`. O app não usa biblioteca de gerência de estado e não
  /// precisa começar a usar por um campo.
  final ValueNotifier<AuthenticatedUser> user;

  int get userId => user.value.id;

  Budgets get budgets => config.budgets;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope não encontrado acima deste widget');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}

/// Fecha o banco quando o app morre. Separado do AppScope porque
/// InheritedWidget não tem dispose.
class DatabaseHolder extends StatefulWidget {
  const DatabaseHolder({super.key, required this.db, required this.child});

  final HistoryDatabase db;
  final Widget child;

  @override
  State<DatabaseHolder> createState() => _DatabaseHolderState();
}

class _DatabaseHolderState extends State<DatabaseHolder> {
  @override
  void dispose() {
    widget.db.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
