import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/catchup_repository.dart';

void main() {
  final windowStart = DateTime.utc(2026, 9, 13, 16, 0, 0);

  CatchupResult result() => CatchupResult(
        serverTime: windowStart.add(const Duration(seconds: 60)),
        windowStart: windowStart,
        messages: const [],
      );

  test('sem since — primeira entrada na sala — não é buraco', () {
    expect(result().hasGapSince(null), isFalse,
        reason: 'quem nunca viu nada não perdeu nada: o histórico é local e '
            'começa vazio, e o servidor nunca foi arquivo');
  });

  test('since dentro da janela: nada se perdeu', () {
    final since = windowStart.add(const Duration(seconds: 8));

    expect(result().hasGapSince(since), isFalse);
  });

  test('since mais antigo que a janela: houve buraco', () {
    final since = windowStart.subtract(const Duration(minutes: 5));

    expect(result().hasGapSince(since), isTrue,
        reason: 'o piso foi recuado até a janela; o que existiu entre o since '
            'e o window_start nunca vai chegar, e sem indício o buraco '
            'existiria sem ninguém saber');
  });

  test('since exatamente no window_start não é buraco', () {
    expect(result().hasGapSince(windowStart), isFalse);
  });

  test('lê o corpo real de GET /rooms/{id}/catchup', () {
    final parsed = CatchupResult.fromJson(const {
      'server_time': '2026-09-13T16:03:24.776469Z',
      'window_start': '2026-09-13T16:02:24.776469Z',
      'messages': [
        {
          'id': 'eb70d78f-0f90-4d83-9db2-0d2d28898a46',
          'room_id': 255,
          'burst_id': 'fbd46da5-f0a9-4754-940b-0768002c7e37',
          'index': 0,
          'user': {'id': 510, 'display_name': 'Marina'},
          'duration_ms': 1000,
          'origin': 'app',
          'format': 'wav/pcm16/16000',
          'size_bytes': 32044,
          'captured_at': '2026-09-13T16:03:18.000000Z',
          'created_at': '2026-09-13T16:03:18.000000Z',
          'expires_at': '2026-09-13T16:08:18.000000Z',
          'audio_url': 'http://servidor/messages/eb70d78f/audio',
        }
      ],
    });

    expect(parsed.messages, hasLength(1));
    expect(parsed.messages.single.authorName, 'Marina');
    expect(parsed.windowStart.isUtc, isTrue);
  });
}
