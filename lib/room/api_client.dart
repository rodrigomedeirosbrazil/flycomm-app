import 'package:dio/dio.dart';

/// Erro de API já traduzido. O servidor sempre responde JSON — há um
/// ForceJsonResponse global —, então 422 traz o mapa de campos inválidos e
/// nunca um redirecionamento para HTML.
class ApiException implements Exception {
  ApiException({required this.statusCode, required this.message, this.errors});

  final int? statusCode;
  final String message;
  final Map<String, List<String>>? errors;

  bool get isValidation => statusCode == 422;
  bool get isConflict => statusCode == 409;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({required String baseUrl, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15),
              headers: {'Accept': 'application/json'},
            ));

  final Dio _dio;
  String? _token;

  Dio get raw => _dio;

  /// Um token novo revoga o anterior daquele dispositivo (confirmado no
  /// DeviceAuthController), então quem chama nunca deve reautenticar "por via
  /// das dúvidas" — derrubaria a própria sessão.
  set token(String? value) {
    _token = value;
    if (value == null) {
      _dio.options.headers.remove('Authorization');
    } else {
      _dio.options.headers['Authorization'] = 'Bearer $value';
    }
  }

  String? get token => _token;

  Future<Response<T>> send<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
  }) async {
    try {
      return await _dio.request<T>(
        path,
        data: data,
        queryParameters: query,
        options: Options(method: method),
      );
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  ApiException _translate(DioException e) {
    final response = e.response;
    final body = response?.data;

    if (body is Map<String, dynamic>) {
      final rawErrors = body['errors'];
      return ApiException(
        statusCode: response?.statusCode,
        message: (body['message'] as String?) ?? e.message ?? 'Erro de rede',
        errors: rawErrors is Map<String, dynamic>
            ? rawErrors.map(
                (k, v) => MapEntry(k, (v as List<dynamic>).cast<String>()))
            : null,
      );
    }

    return ApiException(
      statusCode: response?.statusCode,
      message: e.message ?? 'Erro de rede',
    );
  }
}
