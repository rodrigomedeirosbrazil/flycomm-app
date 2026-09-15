/// Endereços do backend. Vêm de --dart-define porque o IP da LAN muda de rede
/// para rede; nenhum deles tem padrão útil, e falhar cedo e alto é melhor que
/// bater num localhost que não existe dentro do emulador.
class Env {
  const Env._();

  static const httpBase = String.fromEnvironment('FLYCOMM_HTTP');
  static const wsHost = String.fromEnvironment('FLYCOMM_WS_HOST');
  static const wsPort = int.fromEnvironment('FLYCOMM_WS_PORT', defaultValue: 8080);
  static const wsKey = String.fromEnvironment('FLYCOMM_WS_KEY');

  /// Derivado de `FLYCOMM_HTTP`, não de um --dart-define próprio: API e
  /// WebSocket atravessam a mesma borda (nginx/LB), então um esquema e o outro
  /// sempre sobem juntos. Um define separado deixaria digitar `https` com
  /// `ws` — a combinação que ninguém nota até o celular estar em voo.
  static bool get wsUseTls => tlsFor(httpBase);

  static bool tlsFor(String httpBase) => httpBase.startsWith('https://');

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
    if (!httpBase.startsWith('http://') && !httpBase.startsWith('https://')) {
      throw StateError(
        'FLYCOMM_HTTP precisa começar com http:// ou https:// (veio "$httpBase").',
      );
    }
  }
}
