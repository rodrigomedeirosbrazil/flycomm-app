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

/// A sessão de mídia — por enquanto só no iPhone.
///
/// No Android o `audio_service` roda como Foreground Service e exige serviço e
/// receiver declarados no manifesto, mais notificação permanente. Isso é Fase
/// 4, e sem as declarações o `init` derruba o arranque. Enquanto esta fatia for
/// iOS, o Android continua exatamente como estava — sem gesto, e sem risco.
///
/// Antes do `runApp` porque o `AudioService.init` monta o isolate do handler; a
/// árvore de widgets não pode existir antes dele.
Future<MediaButtonHandler?> _startMediaSession() async {
  if (!Platform.isIOS) return null;

  return AudioService.init(builder: MediaButtonHandler.new);
}
