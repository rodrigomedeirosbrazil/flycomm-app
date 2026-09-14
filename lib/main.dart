import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'audio/media_buttons.dart';
import 'env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Env.assertConfigured();
  runApp(FlycommApp(mediaButtons: await _startMediaSession()));
}

/// A sessão de mídia: no iPhone é o `MPRemoteCommandCenter`, no Android é uma
/// `MediaSession` dentro de um Foreground Service.
///
/// **No Android isto antecipa um pedaço da Fase 4.** O serviço sobe com
/// notificação permanente, e sobe já no arranque, porque o handler se declara
/// tocando desde o construtor. Não é comodidade: uma sessão que morre com a
/// tela não recebe botão nenhum, e o gesto é a razão de tudo isto existir. O
/// que **não** vem junto é escuta em segundo plano — para isso faltam o tipo
/// `microphone`, a isenção de bateria e o resto, que continuam sendo Fase 4.
///
/// Antes do `runApp` porque o `AudioService.init` monta o engine compartilhado
/// que a `MainActivity` (uma `AudioServiceActivity`) espera encontrar.
Future<MediaButtonHandler> _startMediaSession() async {
  final handler = await AudioService.init(
    builder: MediaButtonHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'br.com.medeirostec.flycomm.radio',
      androidNotificationChannelName: 'Rádio',
      androidNotificationChannelDescription:
          'Mantém o rádio ouvindo e recebe o gesto do fone.',
      // O serviço não pode cair: derrubá-lo tira a sessão de mídia do ar, e com
      // ela o gesto.
      androidStopForegroundOnPause: false,
    ),
  );

  // O Android manda o botão do fone para o último app que tocou áudio **de
  // verdade** (issuetracker 65344811). O nosso handler não toca nada — ele só
  // escuta —, então sem isto ele nunca se qualifica e o gesto vai para quem
  // tocou música por último. A chamada só toca um silêncio curto por
  // AudioTrack; é a solução do próprio pacote para este caso.
  if (Platform.isAndroid) await AudioService.androidForceEnableMediaButtons();

  return handler;
}
