import 'api_client.dart';
import 'budgets.dart';
import 'server_clock.dart';

/// GET /config é a única rota autenticada por ninguém além de POST /auth/device:
/// não carrega segredo e precisa ser legível antes do primeiro login, porque é
/// dela que saem os orçamentos.
class ConfigRepository {
  ConfigRepository({required this.api, required this.clock});

  final ApiClient api;
  final ServerClock clock;

  Future<ServerConfig> fetch() async {
    final response = await api.send<Map<String, dynamic>>('GET', '/config');
    final receivedAt = DateTime.now().toUtc();

    final config = ServerConfig.fromJson(response.data!);
    clock.sync(serverTime: config.serverTime, receivedAt: receivedAt);

    return config;
  }
}
