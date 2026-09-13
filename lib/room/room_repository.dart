import 'api_client.dart';
import 'models.dart';

class RoomRepository {
  RoomRepository({required this.api});

  final ApiClient api;

  /// A única rota que embrulha em `data`.
  Future<List<Room>> mine() async {
    final response = await api.send<Map<String, dynamic>>('GET', '/rooms');

    return (response.data!['data'] as List<dynamic>)
        .map((e) => Room.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<Room> create({required String name, int? frequencyHz}) async {
    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/rooms',
      data: {
        'name': name,
        if (frequencyHz != null) 'frequency_hz': frequencyHz,
      },
    );

    return Room.fromJson(response.data!);
  }

  /// O servidor normaliza: aceita minúscula, com ou sem hífen, com ou sem FLY.
  Future<Room> join(String inviteCode) async {
    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/rooms/join',
      data: {'invite_code': inviteCode},
    );

    return Room.fromJson(response.data!);
  }

  /// A sala é plana: qualquer membro renomeia e muda a frequência. Enviar
  /// `frequency_hz: null` explicitamente limpa a frequência, e é por isso que
  /// `clearFrequency` existe separado de simplesmente omitir o campo.
  Future<Room> update(
    int roomId, {
    String? name,
    int? frequencyHz,
    bool clearFrequency = false,
  }) async {
    final response = await api.send<Map<String, dynamic>>(
      'PATCH',
      '/rooms/$roomId',
      data: {
        if (name != null) 'name': name,
        if (clearFrequency) 'frequency_hz': null
        else if (frequencyHz != null) 'frequency_hz': frequencyHz,
      },
    );

    return Room.fromJson(response.data!);
  }

  Future<void> leave(int roomId) =>
      api.send<void>('POST', '/rooms/$roomId/leave');
}
