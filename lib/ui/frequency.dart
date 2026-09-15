import 'package:flutter/services.dart';

/// A frequência é guardada como inteiro em Hz e só vira texto aqui.
/// Nula é um estado honesto: "ainda não combinamos a frequência".
String formatFrequency(int? hz) {
  if (hz == null) return 'sem frequência';
  return '${(hz / 1000000).toStringAsFixed(3)} MHz';
}

/// Seis dígitos bastam para qualquer frequência das faixas do rádio, escrita
/// como MHz com decimais (145,550) ou como kHz (145550). O que passa disso é
/// ignorado em vez de recusado: no ar, o piloto não vai ler mensagem de erro.
class FrequencyInput extends TextInputFormatter {
  static final _allowed = RegExp(r'^[0-9]*[.,]?[0-9]*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue previous,
    TextEditingValue next,
  ) {
    if (!_allowed.hasMatch(next.text)) return previous;

    final digits = next.text.replaceAll(RegExp('[^0-9]'), '');

    return digits.length > 6 ? previous : next;
  }
}
