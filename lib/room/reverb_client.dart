import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'models.dart';

/// Nome do canal no fio. No Laravel ele se chama `room.{id}`; o prefixo
/// `presence-` é do protocolo Pusher e precisa estar tanto no subscribe quanto
/// no corpo de /broadcasting/auth.
String presenceChannelFor(int roomId) => 'presence-room.$roomId';

class RoomPresence {
  const RoomPresence({required this.members});

  final List<Member> members;
}

enum ReverbConnection { disconnected, connecting, connected }

/// Cliente do protocolo Pusher falado pelo Reverb, em Dart puro.
///
/// Escrito à mão de propósito: o `pusher_channels_flutter` não consegue apontar
/// para um Reverb próprio — a camada Dart nunca envia `host`, e o nativo do
/// Android só aceita `cluster`, que resolve para `ws-<cluster>.pusher.com`.
/// O protocolo que precisamos é pequeno: conectar, pegar o `socket_id`, trocá-lo
/// por uma assinatura em /broadcasting/auth, assinar o canal e ler eventos.
///
/// O ganho colateral é grande: sem plugin nativo, isto roda em `flutter test`
/// no host, sem emulador.
class ReverbClient {
  ReverbClient({
    required this.api,
    required this.appKey,
    required this.host,
    required this.port,
    this.useTls = false,
    Future<WebSocketChannel> Function(Uri)? connector,
  }) : _connect = connector ?? ((uri) async => WebSocketChannel.connect(uri));

  final ApiClient api;
  final String appKey;
  final String host;
  final int port;
  final bool useTls;
  final Future<WebSocketChannel> Function(Uri) _connect;

  final _messages = StreamController<RoomMessage>.broadcast();
  final _roomUpdates = StreamController<Room>.broadcast();
  final _presence = StreamController<RoomPresence>.broadcast();
  final _connection = StreamController<ReverbConnection>.broadcast();

  /// `message.new` — só metadados, no mesmo formato das outras duas aparições.
  Stream<RoomMessage> get messages => _messages.stream;

  /// `room.updated` — nome e frequência; todo mundo precisa ver a frequência
  /// mudar sem recarregar.
  Stream<Room> get roomUpdates => _roomUpdates.stream;

  Stream<RoomPresence> get presence => _presence.stream;

  /// Emite `connected` a cada (re)assinatura bem-sucedida. É esse sinal que a
  /// RoomSession usa para rodar o catch-up de novo: o caso que a janela de 60 s
  /// foi desenhada para cobrir é justamente o WebSocket que cai e volta.
  Stream<ReverbConnection> get connectionState => _connection.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socket;
  Room? _room;
  final _members = <int, Member>{};

  bool _closing = false;
  int _attempt = 0;

  Uri get _uri => Uri(
        scheme: useTls ? 'wss' : 'ws',
        host: host,
        port: port,
        path: '/app/$appKey',
        queryParameters: {
          'protocol': '7',
          'client': 'flycomm',
          'version': '1.0.0',
        },
      );

  /// [room] entra porque `room.updated` traz só `{id, name, frequency_hz}`:
  /// o código de convite e os membros continuam vindo da resposta HTTP.
  Future<void> connect(Room room) async {
    _room = room;
    _closing = false;
    await _open();
  }

  Future<void> _open() async {
    _emitConnection(ReverbConnection.connecting);

    final channel = await _connect(_uri);
    _channel = channel;

    _socket = channel.stream.listen(
      _onFrame,
      onError: (Object _) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: false,
    );
  }

  void _send(Map<String, dynamic> frame) =>
      _channel?.sink.add(jsonEncode(frame));

  Future<void> _onFrame(dynamic raw) async {
    final frame = jsonDecode(raw as String) as Map<String, dynamic>;
    final event = frame['event'] as String?;

    // O campo `data` chega como String JSON na maior parte dos eventos, mas
    // como objeto em alguns (pusher:ping). Normalizar aqui evita espalhar
    // jsonDecode por toda a classe.
    final data = _decode(frame['data']);

    switch (event) {
      case 'pusher:connection_established':
        _attempt = 0;
        await _subscribe(data!['socket_id'] as String);

      case 'pusher:ping':
        _send({'event': 'pusher:pong', 'data': <String, dynamic>{}});

      case 'pusher_internal:subscription_succeeded':
        _members
          ..clear()
          ..addAll(_parsePresence(data));
        _emitPresence();
        _emitConnection(ReverbConnection.connected);

      case 'pusher_internal:member_added':
        final member = _memberFrom(
          data!['user_id'],
          data['user_info'] as Map<String, dynamic>?,
        );
        _members[member.id] = member;
        _emitPresence();

      case 'pusher_internal:member_removed':
        _members.remove(_asInt(data!['user_id']));
        _emitPresence();

      case 'message.new':
        if (!_messages.isClosed) _messages.add(RoomMessage.fromJson(data!));

      case 'room.updated':
        final updated = _room?.copyWith(
          name: data!['name'] as String,
          frequencyHz: data['frequency_hz'] as int?,
          clearFrequency: data['frequency_hz'] == null,
        );
        if (updated != null) {
          _room = updated;
          _roomUpdates.add(updated);
        }
    }
  }

  /// O servidor devolve `{auth, channel_data}`; os dois vão no subscribe tal
  /// como vieram — `channel_data` é a string exata que foi assinada, e
  /// reserializá-la invalidaria a assinatura.
  Future<void> _subscribe(String socketId) async {
    final channelName = presenceChannelFor(_room!.id);

    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/broadcasting/auth',
      data: {'socket_id': socketId, 'channel_name': channelName},
    );

    _send({
      'event': 'pusher:subscribe',
      'data': {
        'auth': response.data!['auth'],
        'channel_data': response.data!['channel_data'],
        'channel': channelName,
      },
    });
  }

  Map<int, Member> _parsePresence(Map<String, dynamic>? data) {
    final hash = (data?['presence'] as Map<String, dynamic>?)?['hash'];
    if (hash is! Map<String, dynamic>) return {};

    return {
      for (final entry in hash.entries)
        _asInt(entry.key): _memberFrom(
          entry.key,
          entry.value as Map<String, dynamic>?,
        ),
    };
  }

  Member _memberFrom(dynamic userId, Map<String, dynamic>? info) => Member(
        id: _asInt(userId),
        displayName: (info?['display_name'] as String?) ?? 'sem nome',
        role: 'member',
      );

  void _emitPresence() {
    if (_presence.isClosed) return;
    _presence.add(RoomPresence(members: _members.values.toList(growable: false)));
  }

  /// dispose() fecha os controladores, e disconnect() emite. Chamar dispose()
  /// duas vezes — ou disconnect() depois dele — não pode explodir.
  void _emitConnection(ReverbConnection state) {
    if (_connection.isClosed) return;
    _connection.add(state);
  }

  static int _asInt(dynamic value) =>
      value is int ? value : int.parse(value as String);

  static Map<String, dynamic>? _decode(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.isNotEmpty) {
      return jsonDecode(data) as Map<String, dynamic>;
    }
    return null;
  }

  void _scheduleReconnect() {
    if (_closing || _room == null) return;

    _emitConnection(ReverbConnection.disconnected);
    _attempt++;

    // Teto de 8 s: o catch-up só olha 60 s para trás, então esperar mais que
    // isso para reconectar começa a produzir buraco no histórico.
    final wait = Duration(
      milliseconds: (500 * (1 << (_attempt - 1))).clamp(500, 8000),
    );

    Timer(wait, () {
      if (_closing) return;
      _open().catchError((Object _) => _scheduleReconnect());
    });
  }

  Future<void> disconnect() async {
    _closing = true;
    await _socket?.cancel();
    _socket = null;
    await _channel?.sink.close();
    _channel = null;
    _members.clear();
    _emitConnection(ReverbConnection.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
    await _roomUpdates.close();
    await _presence.close();
    await _connection.close();
  }
}
