import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/budgets.dart';

void main() {
  // Corpo real de GET /config, copiado da resposta do servidor.
  const payload = {
    'budgets': {
      'playback_deadline_ms': 30000,
      'radio_relay_deadline_ms': 10000,
      'segment_max_ms': 5000,
      'catchup_window_ms': 60000,
      'blob_ttl_ms': 300000,
    },
    'frequency_bands': [
      {'min_hz': 136000000, 'max_hz': 174000000},
      {'min_hz': 400000000, 'max_hz': 470000000},
    ],
    'server_time': '2026-09-13T16:02:13.690074Z',
  };

  test('lê os cinco orçamentos como Duration', () {
    final config = ServerConfig.fromJson(payload);

    expect(config.budgets.playbackDeadline, const Duration(seconds: 30));
    expect(config.budgets.radioRelayDeadline, const Duration(seconds: 10));
    expect(config.budgets.segmentMax, const Duration(seconds: 5));
    expect(config.budgets.catchupWindow, const Duration(seconds: 60));
    expect(config.budgets.blobTtl, const Duration(minutes: 5));
  });

  test('server_time vira DateTime em UTC, com microssegundos', () {
    final config = ServerConfig.fromJson(payload);

    expect(config.serverTime.isUtc, isTrue);
    expect(config.serverTime.microsecondsSinceEpoch % 1000, 74);
  });

  test('lê a frequência do jeito que o piloto digitou', () {
    final config = ServerConfig.fromJson(payload);

    // Vírgula é o separador do teclado decimal em pt-BR.
    expect(config.frequencyHzFromInput('145,550'), 145550000);
    expect(config.frequencyHzFromInput('145.550'), 145550000);
    // Só dígitos: as faixas são estreitas, então só uma leitura cabe.
    expect(config.frequencyHzFromInput('145550'), 145550000, reason: 'kHz');
    expect(config.frequencyHzFromInput('145550000'), 145550000, reason: 'Hz');
    expect(config.frequencyHzFromInput('146'), 146000000, reason: 'MHz');
    expect(config.frequencyHzFromInput('446'), 446000000);
    expect(config.frequencyHzFromInput(' 146 '), 146000000);
  });

  test('frequência que não cabe em nenhuma faixa e texto inválido dão null', () {
    final config = ServerConfig.fromJson(payload);

    expect(config.frequencyHzFromInput('200'), isNull, reason: 'entre as faixas');
    expect(config.frequencyHzFromInput(''), isNull);
    expect(config.frequencyHzFromInput('abc'), isNull);
    expect(config.frequencyHzFromInput('145,,550'), isNull);
  });

  test('as faixas de rádio validam frequência em Hz inteiro', () {
    final config = ServerConfig.fromJson(payload);

    expect(config.isFrequencyValid(145550000), isTrue);
    expect(config.isFrequencyValid(446000000), isTrue);
    expect(config.isFrequencyValid(200000000), isFalse);
    expect(config.isFrequencyValid(135999999), isFalse);
    expect(config.isFrequencyValid(174000000), isTrue);
  });
}
