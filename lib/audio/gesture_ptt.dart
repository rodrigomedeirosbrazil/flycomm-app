import 'dart:async';

/// Transforma comando de mídia em PTT.
///
/// O gesto do fone é discreto — não existe segurar (ver `MediaButtonHandler`).
/// Sobra alternar: um toque abre o microfone, outro fecha. Isso muda o
/// comportamento em relação ao botão da tela, e a diferença é perigosa: um
/// toque perdido no botão da tela não faz nada, um toque perdido aqui deixa o
/// microfone aberto.
class GesturePtt {
  GesturePtt({
    required Future<void> Function() start,
    required Future<void> Function() stop,
    this.debounce = const Duration(milliseconds: 400),
    required this.ceiling,
  })  : _start = start,
        _stop = stop;

  final Future<void> Function() _start;
  final Future<void> Function() _stop;

  /// Um gesto só pode emitir mais de um comando: no iOS, um toque que chegue
  /// como `play` **e** como `click` abriria e fecharia o microfone no mesmo
  /// instante, e o piloto veria nada acontecer.
  ///
  /// O diagnóstico registra os dois comandos; o alternador consome o primeiro.
  final Duration debounce;

  /// A rede para o segundo toque que não chega — porque o fone não emitiu,
  /// porque o iOS trocou de rota, porque outro app roubou o Now Playing.
  ///
  /// Sem ela o microfone fica aberto e o piloto não tem como saber. Vem do
  /// `segmentMax` do `GET /config` e não de constante daqui: orçamento é do
  /// servidor. Sendo o mesmo teto do segmentador, a fala sai como um segmento
  /// só.
  final Duration ceiling;

  final _changes = StreamController<bool>.broadcast();
  final _problems = StreamController<Object>.broadcast();

  DateTime? _lastAccepted;
  Timer? _ceiling;
  Future<void>? _starting;
  bool _recording = false;

  bool get isRecording => _recording;

  /// Muda quando o microfone abre e quando fecha — inclusive quando fecha
  /// sozinho pelo teto, que é o caso que a tela mais precisa mostrar.
  Stream<bool> get changes => _changes.stream;

  /// A captura não abriu. Quem escuta guarda a causa até alguém ler: quando
  /// isto acontece a tela costuma estar bloqueada, e um aviso que passa não
  /// chega a existir.
  Stream<Object> get problems => _problems.stream;

  /// Um comando de mídia chegou.
  Future<void> handle() async {
    final now = DateTime.now();
    final last = _lastAccepted;
    if (last != null && now.difference(last) < debounce) return;
    _lastAccepted = now;

    if (_recording) {
      await _finish();
      return;
    }

    // Antes do await de propósito: um segundo comando que chegue enquanto o
    // microfone ainda está abrindo tem que ver "gravando", não "parado".
    _recording = true;
    _changes.add(true);

    // O erro é capturado aqui e não relançado: `_starting` é aguardado também
    // por [_finish], e um futuro que estoura em dois lugares derruba um deles
    // sem dono.
    Object? failure;
    _starting = _start().catchError((Object error) => failure = error);
    await _starting;
    _starting = null;

    if (failure != null) {
      // Um segundo comando durante o arranque já pode ter desfeito isto.
      if (_recording) {
        _recording = false;
        _changes.add(false);
      }
      _problems.add(failure!);
      return;
    }

    // O teto conta daqui, não do gesto. Entre um e outro há o aviso sonoro, a
    // compensação de latência do fone e o arranque do plugin — medidos em
    // ~800 ms no iPhone. Contando do gesto, um teto de 5 s entregava 4,2 s de
    // fala, e a diferença ia inteira para o silêncio do começo.
    //
    // O `if` importa: um segundo comando durante o arranque já encerrou isto,
    // e armar o cronômetro agora deixaria um disparo órfão.
    if (_recording) _ceiling = Timer(ceiling, () => unawaited(_finish()));
  }

  Future<void> _finish() async {
    if (!_recording) return;
    _recording = false;

    _ceiling?.cancel();
    _ceiling = null;
    _changes.add(false);

    // Parar no meio de um começo não para nada: o gravador ainda não estava
    // gravando quando o `stop` chegasse, e a captura seguiria aberta sem teto,
    // sem faixa vermelha e sem ninguém para fechá-la.
    await _starting;
    await _stop();
  }

  Future<void> dispose() async {
    _ceiling?.cancel();
    await _changes.close();
    await _problems.close();
  }
}
