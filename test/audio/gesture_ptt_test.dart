import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/gesture_ptt.dart';

void main() {
  late List<String> calls;
  GesturePtt? open;

  GesturePtt build({
    Duration debounce = const Duration(milliseconds: 40),
    Duration ceiling = const Duration(milliseconds: 200),
    Duration startCost = Duration.zero,
  }) =>
      open = GesturePtt(
        start: () async {
          await Future<void>.delayed(startCost);
          calls.add('start');
        },
        stop: () async => calls.add('stop'),
        debounce: debounce,
        ceiling: ceiling,
      );

  setUp(() => calls = []);
  tearDown(() async => open?.dispose());

  test('um toque abre o microfone, o seguinte fecha', () async {
    final ptt = build();

    await ptt.handle();
    expect(ptt.isRecording, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    await ptt.handle();

    expect(ptt.isRecording, isFalse);
    expect(calls, ['start', 'stop']);
  });

  test('um gesto que emite dois comandos não abre e fecha na mesma hora',
      () async {
    final ptt = build();

    await ptt.handle();
    await ptt.handle();

    expect(ptt.isRecording, isTrue);
    expect(calls, ['start']);
  });

  test('sem o segundo toque, o teto fecha sozinho', () async {
    final ptt = build();

    await ptt.handle();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(ptt.isRecording, isFalse);
    expect(calls, ['start', 'stop']);
  });

  test('o teto conta a partir da gravação, não do gesto', () async {
    // Abrir o microfone custa: aviso sonoro, latência do fone, plugin. Contando
    // do gesto, um teto de 200 ms entregaria 50 ms de fala.
    final ptt = build(
      ceiling: const Duration(milliseconds: 200),
      startCost: const Duration(milliseconds: 150),
    );

    final pressed = DateTime.now();
    await ptt.handle();

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(ptt.isRecording, isTrue, reason: 'fechou contando do gesto');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ptt.isRecording, isFalse);

    final total = DateTime.now().difference(pressed);
    expect(total, greaterThan(const Duration(milliseconds: 300)));
  });

  test('um comando durante o arranque não deixa a captura sem teto', () async {
    final ptt = build(
      debounce: Duration.zero,
      ceiling: const Duration(milliseconds: 200),
      startCost: const Duration(milliseconds: 150),
    );

    final first = ptt.handle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await ptt.handle();
    await first;

    expect(ptt.isRecording, isFalse);
    // O `stop` espera o `start` terminar: parar antes não pararia nada.
    expect(calls, ['start', 'stop']);
  });

  test('captura que não abre volta o estado atrás e conta o porquê', () async {
    // O iOS recusa abrir o microfone com o app em segundo plano. Sem isto o
    // alternador ficava "gravando" para sempre, sem teto e sem ninguém avisado.
    final ptt = GesturePtt(
      start: () async => throw StateError('o iPhone recusou o microfone'),
      stop: () async => calls.add('stop'),
      debounce: const Duration(milliseconds: 40),
      ceiling: const Duration(milliseconds: 100),
    );
    open = ptt;

    final problems = <Object>[];
    ptt.problems.listen(problems.add);

    await ptt.handle();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(ptt.isRecording, isFalse);
    expect(problems, hasLength(1));
    expect(calls, isEmpty, reason: 'não havia captura para parar');

    // E o teto não pode disparar sobre uma gravação que nunca existiu.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(calls, isEmpty);
  });

  test('depois de uma falha, o gesto seguinte ainda abre', () async {
    var refuse = true;
    final ptt = GesturePtt(
      start: () async {
        if (refuse) throw StateError('recusado');
        calls.add('start');
      },
      stop: () async => calls.add('stop'),
      debounce: Duration.zero,
      ceiling: const Duration(milliseconds: 500),
    );
    open = ptt;
    ptt.problems.listen((_) {});

    await ptt.handle();
    refuse = false;
    await ptt.handle();

    expect(ptt.isRecording, isTrue);
    expect(calls, ['start']);
  });

  test('o teto não fecha uma gravação que o toque já fechou', () async {
    final ptt = build();

    await ptt.handle();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await ptt.handle();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(calls, ['start', 'stop']);
  });
}
