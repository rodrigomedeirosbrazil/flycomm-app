import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/wav.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/config_repository.dart';
import 'package:flycomm/room/device_identity.dart';
import 'package:flycomm/room/message_api.dart';
import 'package:flycomm/room/room_repository.dart';
import 'package:flycomm/room/server_clock.dart';
import 'package:uuid/uuid.dart';

import 'env.dart';

void main() {
  const uuid = Uuid();

  late MessageApi messages;
  late int roomId;
  late Duration segmentMax;

  Uint8List tone(int ms) => wrapPcmInWav(
      Uint8List.fromList(List.generate(ms * bytesPerMs, (i) => i % 256)));

  OutgoingSegment segment({
    required String id,
    required String burstId,
    int index = 0,
    int durationMs = 1000,
    DateTime? capturedAt,
  }) =>
      OutgoingSegment(
        id: id,
        roomId: roomId,
        burstId: burstId,
        index: index,
        durationMs: durationMs,
        capturedAt: capturedAt ?? DateTime.now().toUtc(),
        wavBytes: tone(durationMs),
      );

  setUpAll(() async {
    final api = ApiClient(baseUrl: httpBase);
    final clock = ServerClock();

    final seeded = seededDevices['rodrigo']!;
    await AuthRepository(api: api).authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );

    segmentMax =
        (await ConfigRepository(api: api, clock: clock).fetch()).budgets.segmentMax;
    roomId = (await RoomRepository(api: api).join('FLY-TEST')).id;
    messages = MessageApi(api: api);
  });

  test('sobe um segmento e recebe o metadado completo de volta', () async {
    final id = uuid.v4();

    final published = await messages.publish(
      segment(id: id, burstId: uuid.v4()),
    );

    expect(published.id, id, reason: 'o id é do app, não do servidor');
    expect(published.origin, 'app');
    expect(published.authorName, isNotNull);
    expect(published.createdAt.isUtc, isTrue);
    expect(published.expiresAt.isAfter(published.createdAt), isTrue);
    expect(published.audioUrl, contains('/messages/$id/audio'));
  });

  test('reenviar o mesmo id é idempotente: mesma mensagem, sem duplicar', () async {
    final id = uuid.v4();
    final burstId = uuid.v4();

    final first = await messages.publish(segment(id: id, burstId: burstId));
    final second = await messages.publish(segment(id: id, burstId: burstId));

    expect(second.id, first.id);
    expect(second.createdAt, first.createdAt,
        reason: 'a retentativa devolve a gravada, não cria outra');
  });

  test('o áudio volta byte a byte igual pelo audio_url', () async {
    final id = uuid.v4();
    final sent = tone(1000);

    final published = await messages.publish(
      OutgoingSegment(
        id: id,
        roomId: roomId,
        burstId: uuid.v4(),
        index: 0,
        durationMs: 1000,
        capturedAt: DateTime.now().toUtc(),
        wavBytes: sent,
      ),
    );

    final received = await messages.download(published.audioUrl);

    expect(received, equals(sent),
        reason: 'o servidor trata áudio como bytes opacos');
    expect(published.sizeBytes, sent.length);
  });

  test('duração acima de segment_max é recusada com 422', () async {
    await expectLater(
      messages.publish(segment(
        id: uuid.v4(),
        burstId: uuid.v4(),
        durationMs: segmentMax.inMilliseconds + 1,
      )),
      throwsA(isA<ApiException>().having((e) => e.isValidation, 'isValidation', isTrue)),
      reason: 'a regra de 5 s é do sistema, não só do app: um cliente que '
          'ignore a segmentação é recusado pelo servidor',
    );
  });

  test('a fala de dois minutos atrás ainda sobe: é ela que entra no histórico',
      () async {
    final capturedAt =
        DateTime.now().toUtc().subtract(const Duration(minutes: 2));

    final published = await messages.publish(
      segment(id: uuid.v4(), burstId: uuid.v4(), capturedAt: capturedAt),
    );

    expect(published.capturedAt, isNotNull);
    expect(published.createdAt.difference(published.capturedAt!),
        greaterThan(const Duration(minutes: 1)),
        reason: 'created_at responde quando chegou, captured_at quando foi '
            'dito — e é a diferença entre os dois que diz que ninguém ouviu '
            'ao vivo');
  });

  test('captured_at à frente do relógio do servidor é recusado com 422',
      () async {
    await expectLater(
      messages.publish(segment(
        id: uuid.v4(),
        burstId: uuid.v4(),
        capturedAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      )),
      throwsA(isA<ApiException>()
          .having((e) => e.isValidation, 'isValidation', isTrue)),
      reason: 'um aparelho adiantado faria a fala nunca envelhecer e tocar ao '
          'vivo horas depois',
    );
  });

  test('captured_at fora da janela de entrega é recusado com 422', () async {
    await expectLater(
      messages.publish(segment(
        id: uuid.v4(),
        burstId: uuid.v4(),
        capturedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 30)),
      )),
      throwsA(isA<ApiException>()
          .having((e) => e.isValidation, 'isValidation', isTrue)),
      reason: 'o app já não deveria estar insistindo nisso; o 422 é terminal '
          'para ele e vira NÃO ENTREGUE',
    );
  });

  test('uma rajada de três segmentos guarda burst_id e índice', () async {
    final burstId = uuid.v4();

    for (var index = 0; index < 3; index++) {
      final published = await messages.publish(
        segment(id: uuid.v4(), burstId: burstId, index: index),
      );

      expect(published.burstId, burstId);
      expect(published.index, index);
    }
  });
}
