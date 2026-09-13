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
  /// Quantas vezes insistir num erro de transporte antes de desistir.
  ///
  /// O app vive no bolso e o sistema derruba conexões ao suspendê-lo. O
  /// `HttpClient` do Dart mantém um pool e reaproveita um socket que o iOS já
  /// fechou, e a falha que sai disso é `ApiException(null): connection reused`
  /// — sem `statusCode`, porque não houve resposta HTTP nenhuma. Do lado do
  /// servidor a requisição aparece com 200: ele atendeu, o aparelho é que não
  /// recebeu.
  ///
  /// Uma segunda tentativa pega uma conexão nova e passa. Sem isto, toda fala
  /// que chega logo depois de o app voltar do segundo plano é perdida — e o
  /// piloto vê "mensagem atrasada sem áudio", que não diz nada sobre a causa.
  static const _downloadAttempts = 3;

  Future<Uint8List> download(String audioUrl) async {
    ApiException? lastFailure;

    for (var attempt = 1; attempt <= _downloadAttempts; attempt++) {
      try {
        final response = await api.raw.get<List<int>>(
          audioUrl,
          options: Options(responseType: ResponseType.bytes),
        );
        return Uint8List.fromList(response.data!);
      } on DioException catch (e) {
        final failure = ApiException(
          statusCode: e.response?.statusCode,
          message: '${e.message ?? 'falha ao baixar o áudio'} '
              '[${e.requestOptions.uri}]',
        );

        // Erro com resposta é do servidor — 404 de blob vencido, 403 de quem
        // não é membro — e insistir só repete a recusa. Sem resposta é
        // transporte, e aí a próxima tentativa tem chance.
        if (failure.statusCode != null) throw failure;

        lastFailure = failure;
        if (attempt < _downloadAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
        }
      }
    }

    throw lastFailure!;
  }
}
