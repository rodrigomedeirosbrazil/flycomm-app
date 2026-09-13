import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/message_api.dart';

/// Falha as primeiras [failures] tentativas com erro de transporte — sem
/// resposta HTTP, que é exatamente a forma do `connection reused` — e depois
/// devolve os bytes.
class _FlakyAdapter implements HttpClientAdapter {
  _FlakyAdapter({required this.failures, required this.body});

  int failures;
  final List<int> body;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;

    if (failures > 0) {
      failures--;
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'connection reused',
      );
    }

    return ResponseBody.fromBytes(body, 200);
  }

  @override
  void close({bool force = false}) {}
}

/// Recusa com uma resposta HTTP de verdade.
class _RefusingAdapter implements HttpClientAdapter {
  _RefusingAdapter(this.statusCode);

  final int statusCode;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    throw DioException.badResponse(
      statusCode: statusCode,
      requestOptions: options,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: statusCode,
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  MessageApi apiWith(HttpClientAdapter adapter) {
    final dio = Dio(BaseOptions(baseUrl: 'http://servidor'))
      ..httpClientAdapter = adapter;
    return MessageApi(api: ApiClient(baseUrl: 'http://servidor', dio: dio));
  }

  test('insiste no erro de transporte e devolve os bytes', () async {
    // O app vive no bolso: o iOS derruba a conexão ao suspender, o pool do
    // HttpClient reaproveita o socket morto, e sai ApiException(null).
    final adapter = _FlakyAdapter(failures: 2, body: [1, 2, 3, 4]);

    final bytes = await apiWith(adapter).download('http://servidor/audio');

    expect(bytes, Uint8List.fromList([1, 2, 3, 4]));
    expect(adapter.calls, 3, reason: 'duas falhas e um acerto');
  });

  test('desiste quando o transporte falha em todas as tentativas', () async {
    final adapter = _FlakyAdapter(failures: 99, body: const []);

    await expectLater(
      apiWith(adapter).download('http://servidor/audio'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', isNull)),
    );
    expect(adapter.calls, 3, reason: 'não insiste para sempre');
  });

  test('não insiste quando o servidor recusa: a resposta não vai mudar', () async {
    // 404 é blob vencido. Repetir só repete a recusa e atrasa o aviso ao
    // piloto de que aquele áudio não existe mais.
    final adapter = _RefusingAdapter(404);

    await expectLater(
      apiWith(adapter).download('http://servidor/audio'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)),
    );
    expect(adapter.calls, 1);
  });
}
