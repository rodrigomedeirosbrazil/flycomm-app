package br.com.medeirostec.flycomm

import com.ryanheise.audioservice.AudioServiceActivity

// `AudioServiceActivity` e não `FlutterActivity`: é dela que vem o código que
// liga esta activity ao `FlutterEngine` compartilhado do audio_service. Sem
// isso o serviço sobe com um engine próprio, e os callbacks de botão de mídia
// nunca encontram o nosso handler.
class MainActivity : AudioServiceActivity()
