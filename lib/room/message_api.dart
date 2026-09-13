import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_client.dart';
import 'models.dart';

/// O que o app grava e ainda não subiu.
class OutgoingSegment {
  const OutgoingSegment({
    required this.id,
    required this.roomId,
    required this.burstId,
    required this.index,
    required this.durationMs,
    required this.capturedAt,
    required this.wavBytes,
  });

  /// uuid gerado pelo APP. É o que torna o upload idempotente: a retentativa
  /// insiste durante toda a janela de validade, e sem um id estável cada
  /// tentativa em rede ruim criaria uma mensagem duplicada na sala.
  final String id;

  final int roomId;
  final String burstId;
  final int index;
  final int durationMs;
  final DateTime capturedAt;
  final Uint8List wavBytes;
}

class MessageApi {
  MessageApi({required this.api});

  final ApiClient api;

  /// O valor de `format` que a spec manda enviar na Fase 2.
  ///
  /// O servidor grava e devolve `wav/pcm16/16000` na sua própria rajada de
  /// demonstração — divergência registrada na seção 0.1 deste plano, a ser
  /// resolvida com um commit no repo `flycomm`. O app NÃO condiciona
  /// reprodução a este valor: ele decodifica WAV sempre, então as duas
  /// grafias tocam.
  static const format = 'wav-pcm16-16k';

  /// 201 quando a mensagem é nova, 200 quando o id já existia — e nesse caso
  /// o servidor devolve a mensagem gravada sem republicar o evento.
  Future<RoomMessage> publish(OutgoingSegment segment) async {
    final form = FormData.fromMap({
      'id': segment.id,
      'burst_id': segment.burstId,
      'index': segment.index,
      'duration_ms': segment.durationMs,
      'origin': 'app',
      'format': format,
      'captured_at': segment.capturedAt.toUtc().toIso8601String(),
      'audio': MultipartFile.fromBytes(
        segment.wavBytes,
        filename: '${segment.id}.wav',
      ),
    });

    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/rooms/${segment.roomId}/messages',
      data: form,
    );

    return RoomMessage.fromJson(response.data!);
  }

  /// O endpoint responde `application/octet-stream` com `Accept-Ranges: bytes`
  /// — retomável, para sobreviver a sinal ruim.
  Future<Uint8List> download(String audioUrl) async {
    try {
      final response = await api.raw.get<List<int>>(
        audioUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data!);
    } on DioException catch (e) {
      throw ApiException(
        statusCode: e.response?.statusCode,
        message: e.message ?? 'falha ao baixar o áudio',
      );
    }
  }
}
