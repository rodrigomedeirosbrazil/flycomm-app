import 'dart:async';

import 'package:audio_service/audio_service.dart';

/// Um comando de mídia que chegou de fora do app: gesto no fone, botão na tela
/// bloqueada, central de controle.
class MediaCommand {
  const MediaCommand({required this.at, required this.name});

  /// Relógio local de propósito: isto ordena linhas de log, não decide frescor
  /// de fala. O relógio do servidor não tem nada a ver com quando um botão foi
  /// apertado.
  final DateTime at;

  /// O callback que o sistema chamou, cru — `click media`, `skipToNext`.
  ///
  /// Cru porque a pergunta deste build é exatamente essa: o que o fone emite.
  /// Um nome já traduzido para "PTT" esconderia a resposta.
  final String name;
}

/// A sessão de mídia do app. **Não toca nada** — existe para o gesto do fone
/// ter para onde chegar.
///
/// Sem uma sessão de mídia o gesto não se perde: ele vai para outro app. No
/// Android 8+ o evento AVRCP é roteado para a última `MediaSession` que tocou
/// áudio local; no iOS o `MPRemoteCommandCenter` entrega ao app que é o Now
/// Playing. O `just_audio` sozinho não registra nenhuma das duas, então hoje o
/// gesto vai para quem tocou música por último.
///
/// Não existe segurar. O lado Android do `audio_service` só olha
/// `KeyEvent.ACTION_DOWN` e descarta o `ACTION_UP`; o iOS entrega comandos
/// avulsos. "Segure para falar" não tem como ser expresso por este caminho —
/// ver [GesturePtt].
class MediaButtonHandler extends BaseAudioHandler {
  MediaButtonHandler() {
    // O iOS monta o nowPlayingInfo a partir daqui. Sem item, o app não tem
    // como se apresentar como Now Playing.
    mediaItem.add(const MediaItem(id: 'flycomm-radio', title: 'Rádio'));
    _announce();
  }

  final _commands = StreamController<MediaCommand>.broadcast();
  final _log = <MediaCommand>[];

  /// Cada comando, na hora em que chega.
  Stream<MediaCommand> get commands => _commands.stream;

  /// O histórico do diagnóstico, mais recente primeiro.
  List<MediaCommand> get log => List.unmodifiable(_log);

  /// ANDAIME QUE SUSTENTA PESO — ler antes de mexer.
  ///
  /// `playing: true` não é cosmético e não é verdade: este handler não toca
  /// nada. Mas o plugin iOS só **cria** o `MPRemoteCommandCenter` quando chega
  /// um `playbackState` com `playing` verdadeiro (`AudioServicePlugin.m:179`),
  /// e nunca o desfaz depois. Um handler honesto, que se declarasse parado,
  /// não receberia comando nenhum — e falharia em silêncio, que é o pior jeito
  /// de falhar aqui.
  ///
  /// `systemActions` é a segunda metade da mesma armadilha: no iOS, next e
  /// previous só são habilitados se a ação estiver declarada. Sem elas só o
  /// play/pause chega, e um fone que mande "próxima faixa" pareceria mudo.
  void _announce() {
    playbackState.add(PlaybackState(
      playing: true,
      processingState: AudioProcessingState.ready,
      controls: const [
        MediaControl.pause,
        MediaControl.skipToNext,
        MediaControl.skipToPrevious,
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
    ));
  }

  void _record(String name) {
    final command = MediaCommand(at: DateTime.now(), name: name);

    _log.insert(0, command);
    if (_log.length > 60) _log.removeLast();

    _commands.add(command);
  }

  // Os seis callbacks, porque as duas plataformas repartem os comandos de
  // formas diferentes e cobrir só um lado deixa metade dos gestos invisível:
  //
  //   Android — PLAY, PAUSE, PLAY_PAUSE, HEADSETHOOK, NEXT e PREVIOUS caem
  //             todos em `click`, já traduzidos para media/next/previous.
  //   iOS     — só o togglePlayPause vira `click`; play, pause, nextTrack e
  //             previousTrack chegam pelos métodos próprios.
  //
  // Nenhum deles mexe no playbackState: rebaixar `playing` desmontaria o
  // command center e o gesto seguinte não chegaria.

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async =>
      _record('click ${button.name}');

  @override
  Future<void> play() async => _record('play');

  @override
  Future<void> pause() async => _record('pause');

  @override
  Future<void> stop() async => _record('stop');

  @override
  Future<void> skipToNext() async => _record('skipToNext');

  @override
  Future<void> skipToPrevious() async => _record('skipToPrevious');

  @override
  Future<void> fastForward() async => _record('fastForward');

  @override
  Future<void> rewind() async => _record('rewind');
}
