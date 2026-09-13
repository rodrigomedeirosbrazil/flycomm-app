/// Endereços do backend. Vêm de --dart-define porque o IP da LAN muda de rede
/// para rede; nenhum deles tem padrão útil, e falhar cedo e alto é melhor que
/// bater num localhost que não existe dentro do emulador.
class Env {
  const Env._();

  static const httpBase = String.fromEnvironment('FLYCOMM_HTTP');
  static const wsHost = String.fromEnvironment('FLYCOMM_WS_HOST');
  static const wsPort = int.fromEnvironment('FLYCOMM_WS_PORT', defaultValue: 8080);
  static const wsKey = String.fromEnvironment('FLYCOMM_WS_KEY');

  /// Chame no arranque: um --dart-define esquecido vira uma falha imediata e
  /// legível, não um timeout de trinta segundos numa tela em branco.
  static void assertConfigured() {
    final missing = <String>[
      if (httpBase.isEmpty) 'FLYCOMM_HTTP',
      if (wsHost.isEmpty) 'FLYCOMM_WS_HOST',
      if (wsKey.isEmpty) 'FLYCOMM_WS_KEY',
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'Faltam --dart-define: ${missing.join(', ')}. '
        'Veja docs/superpowers/plans/2026-09-13-fase-2-app-flutter.md, seção 2.',
      );
    }
  }
}
