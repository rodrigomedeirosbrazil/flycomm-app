class Member {
  const Member({
    required this.id,
    required this.displayName,
    required this.role,
    this.joinedAt,
  });

  final int id;
  final String displayName;
  final String role;
  final DateTime? joinedAt;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
        id: json['id'] as int,
        displayName: json['display_name'] as String,
        // O vínculo já nasce com role, todos `member`, ninguém checando nada:
        // quando o modelo de papéis chegar, é escrever policies, não migrar.
        role: (json['role'] as String?) ?? 'member',
        joinedAt: json['joined_at'] == null
            ? null
            : DateTime.parse(json['joined_at'] as String).toUtc(),
      );
}

class Room {
  const Room({
    required this.id,
    required this.name,
    required this.frequencyHz,
    required this.inviteCode,
    required this.createdBy,
    required this.members,
  });

  final int id;
  final String name;

  /// Inteiro em Hz, nullable. Nullable descreve com honestidade o estado
  /// "ainda não combinamos a frequência", que continua real depois da Fase 3.
  final int? frequencyHz;
  final String inviteCode;
  final int createdBy;
  final List<Member> members;

  Room copyWith({String? name, int? frequencyHz, bool clearFrequency = false}) =>
      Room(
        id: id,
        name: name ?? this.name,
        frequencyHz: clearFrequency ? null : (frequencyHz ?? this.frequencyHz),
        inviteCode: inviteCode,
        createdBy: createdBy,
        members: members,
      );

  factory Room.fromJson(Map<String, dynamic> json) => Room(
        id: json['id'] as int,
        name: json['name'] as String,
        frequencyHz: json['frequency_hz'] as int?,
        inviteCode: json['invite_code'] as String,
        createdBy: json['created_by'] as int,
        members: ((json['members'] as List<dynamic>?) ?? const [])
            .map((e) => Member.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// O metadado de uma mensagem, idêntico nos três lugares onde ela aparece:
/// o evento `message.new`, a resposta de POST /rooms/{id}/messages e o
/// catch-up. Três definições divergiriam justamente onde o app precisa tratar
/// as três como a mesma coisa.
class RoomMessage {
  const RoomMessage({
    required this.id,
    required this.roomId,
    required this.burstId,
    required this.index,
    required this.authorId,
    required this.authorName,
    required this.durationMs,
    required this.origin,
    required this.format,
    required this.sizeBytes,
    required this.capturedAt,
    required this.createdAt,
    required this.expiresAt,
    required this.audioUrl,
  });

  final String id;
  final int roomId;
  final String burstId;
  final int index;

  /// Nulos quando `origin` é `radio`: quem só tem rádio não é membro da sala e
  /// não há como identificá-lo a partir do áudio.
  final int? authorId;
  final String? authorName;

  final int durationMs;
  final String origin;
  final String format;
  final int sizeBytes;
  final DateTime? capturedAt;

  /// A autoridade de frescor. É contra este carimbo — emitido pelo servidor —
  /// que a idade é medida, nunca contra `capturedAt`, que é do cliente.
  final DateTime createdAt;

  final DateTime expiresAt;
  final String audioUrl;

  factory RoomMessage.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>?;

    return RoomMessage(
      id: json['id'] as String,
      roomId: json['room_id'] as int,
      burstId: json['burst_id'] as String,
      index: json['index'] as int,
      authorId: user?['id'] as int?,
      authorName: user?['display_name'] as String?,
      durationMs: json['duration_ms'] as int,
      origin: json['origin'] as String,
      format: json['format'] as String,
      sizeBytes: json['size_bytes'] as int,
      capturedAt: json['captured_at'] == null
          ? null
          : DateTime.parse(json['captured_at'] as String).toUtc(),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      audioUrl: json['audio_url'] as String,
    );
  }
}
