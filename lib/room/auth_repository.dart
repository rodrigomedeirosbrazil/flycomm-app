import 'api_client.dart';
import 'device_identity.dart';

class AuthenticatedUser {
  const AuthenticatedUser({required this.id, required this.displayName});

  final int id;
  final String displayName;

  factory AuthenticatedUser.fromJson(Map<String, dynamic> json) =>
      AuthenticatedUser(
        id: json['id'] as int,
        displayName: json['display_name'] as String,
      );
}

class AuthRepository {
  AuthRepository({required this.api});

  final ApiClient api;

  /// Cria ou recupera o usuário. O display_name só vale na criação — numa
  /// recuperação o servidor o ignora, porque o nome canônico vive lá e quem o
  /// muda é PATCH /me.
  ///
  /// Cada chamada emite um token novo e revoga o anterior daquele dispositivo:
  /// chamar isto "por via das dúvidas" derruba a própria sessão.
  Future<AuthenticatedUser> authenticate(
    DeviceCredentials credentials, {
    required String displayName,
  }) async {
    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/auth/device',
      data: {
        'identifier': credentials.identifier,
        'secret': credentials.secret,
        'display_name': displayName,
      },
    );

    final body = response.data!;
    api.token = body['token'] as String;

    return AuthenticatedUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<AuthenticatedUser> updateDisplayName(String displayName) async {
    final response = await api.send<Map<String, dynamic>>(
      'PATCH',
      '/me',
      data: {'display_name': displayName},
    );

    return AuthenticatedUser.fromJson(response.data!);
  }
}
