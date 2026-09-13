import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Os arquivos de áudio do histórico, no dispositivo. Permanentes: o servidor
/// apaga o blob depois de `blob_ttl_ms`, e o que fica é isto.
class AudioStore {
  AudioStore(this._root);

  final Directory _root;

  static Future<AudioStore> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/audio');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return AudioStore(dir);
  }

  String pathFor(String messageId) => '${_root.path}/$messageId.wav';

  bool has(String messageId) => File(pathFor(messageId)).existsSync();

  Future<String> write(String messageId, Uint8List bytes) async {
    final file = File(pathFor(messageId));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List> read(String messageId) =>
      File(pathFor(messageId)).readAsBytes();
}
