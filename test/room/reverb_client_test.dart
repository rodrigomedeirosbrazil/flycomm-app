import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/models.dart';
import 'package:flycomm/room/reverb_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Um WebSocket de mentira: dá para empurrar quadros e erros pelo lado do
/// servidor sem rede nenhuma.
class _FakeChannel implements WebSocketChannel {
  final _incoming = StreamController<dynamic>();

  bool get closed => _incoming.isClosed;

  void push(Map<String, dynamic> frame) => _incoming.add(jsonEncode(frame));
  void fail() => _incoming.addError(StateError('conexão caiu'));
  Future<void> finish() => _incoming.close();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink();

  @override
  Future<void> get ready => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  @override
  void add(dynamic data) {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const room = Room(
    id: 255,
    name: 'Sala',
    frequencyHz: null,
    inviteCode: 'FLY-TEST',
    createdBy: 1,
    members: [],
  );

  late List<_FakeChannel> opened;
  late ReverbClient reverb;

  setUp(() {
    opened = [];
    reverb = ReverbClient(
      api: ApiClient(baseUrl: 'http://servidor'),
      appKey: 'k',
      host: 'localhost',
      port: 8080,
      connector: (_) async {
        final channel = _FakeChannel();
        opened.add(channel);
        return channel;
      },
    );
  });

  tearDown(() => reverb.dispose());

  Map<String, dynamic> messageFrame(String id) => {
        'event': 'message.new',
        'channel': presenceChannelFor(room.id),
        'data': jsonEncode({
          'id': id,
          'room_id': room.id,
          'burst_id': 'b-1',
          'index': 0,
          'author_id': 510,
          'author_name': 'Marina',
          'duration_ms': 5000,
          'origin': 'app',
          'format': 'wav-pcm16-16k',
          'size_bytes': 160044,
          'captured_at': '2026-09-13T16:00:00Z',
          'created_at': '2026-09-13T16:00:01Z',
          'expires_at': '2026-09-13T16:05:01Z',
          'audio_url': 'http://servidor/messages/$id/audio',
        }),
      };

  test('uma queda que dá erro E fim reconecta uma vez só', () async {
    await reverb.connect(room);
    expect(opened, hasLength(1));

    opened.first.fail();
    await opened.first.finish();

    await Future<void>.delayed(const Duration(milliseconds: 2000));

    expect(opened, hasLength(2),
        reason: 'erro e fim são a mesma queda: dois sockets vivos entregam '
            'cada fala duas vezes');
  });

  test('reconectar descarta o socket anterior', () async {
    await reverb.connect(room);
    final first = opened.first;

    final received = <String>[];
    reverb.messages.listen((m) => received.add(m.id));

    first.fail();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(opened, hasLength(2));

    // O socket velho continua de pé do lado do servidor e vai entregar a mesma
    // fala que o novo entrega.
    first.push(messageFrame('11111111-1111-1111-1111-111111111111'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(received, isEmpty,
        reason: 'o socket abandonado continua entregando message.new');
  });
}
