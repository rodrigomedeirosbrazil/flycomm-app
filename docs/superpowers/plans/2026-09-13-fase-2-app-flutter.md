# Fase 2 — App Flutter da sala de pilotos: plano de implementação

> **Para agentes:** SUB-SKILL OBRIGATÓRIA: use `superpowers:subagent-driven-development`
> (recomendado) ou `superpowers:executing-plans` para executar este plano tarefa a
> tarefa. Os passos usam checkbox (`- [ ]`) para acompanhamento.

**Objetivo:** construir o app Flutter da Fase 2 — sala, presença, PTT, fila FIFO de
reprodução com prazo de validade e histórico local permanente — contra o
`flycomm-server` real, até cumprir os cinco critérios da seção 8 da spec.

**Arquitetura:** lógica de domínio em Dart puro, sem dependência de Flutter, para que
as regras que carregam o projeto (desvio do relógio do servidor, corte de 5 s, fila
FIFO com descarte por prazo, meio-duplex) sejam testáveis com `flutter test` sem
emulador. As bordas — HTTP, WebSocket, microfone, alto-falante, SQLite — ficam em
classes finas que essas regras consomem. O estado da tela é `Stream` exposto por
controladores Dart puros, consumido com `StreamBuilder`; não há pacote de gerência de
estado, porque não há estado que justifique um.

**Stack:** Flutter 3.47 / Dart 3.13 · `dio` (HTTP, Range) · `pusher_channels_flutter`
(Reverb) · `record` (captura PCM em stream) · `just_audio` (reprodução) · `drift`
(SQLite) · `flutter_secure_storage` (segredo do dispositivo) · `uuid` ·
`permission_handler` · `path_provider`.

---

## 0. Antes de começar: o que já foi verificado contra o servidor real

Tudo abaixo foi confirmado por requisição real em `http://192.168.15.112:8000` em
2026-09-13, não lido da spec. Quem executar este plano pode confiar nestes formatos.

**`GET /config`** (sem token):

```json
{"budgets":{"playback_deadline_ms":30000,"radio_relay_deadline_ms":10000,
"segment_max_ms":5000,"catchup_window_ms":60000,"blob_ttl_ms":300000},
"frequency_bands":[{"min_hz":136000000,"max_hz":174000000},
{"min_hz":400000000,"max_hz":470000000}],
"server_time":"2026-09-13T16:02:13.690074Z"}
```

**`POST /auth/device`** → `{"token":"4|hPY…","user":{"id":509,"display_name":"Rodrigo"}}`.
Tem `throttle:20,1` — 20 chamadas por minuto por IP. Cada chamada **revoga o token
anterior daquele dispositivo**, então dois emuladores não podem compartilhar o mesmo
`identifier`.

**Empacotamento das respostas** — só `GET /rooms` embrulha em `data`:

| Rota | Corpo |
|---|---|
| `GET /rooms` | `{"data":[ {sala}, … ]}` |
| `POST /rooms`, `PATCH /rooms/{id}`, `POST /rooms/join` | `{sala}` cru |
| `POST /rooms/{id}/messages` | `{mensagem}` cru — **201** nova, **200** id repetido |
| `GET /rooms/{id}/catchup` | `{server_time, window_start, messages:[…]}` |
| `PATCH /me` | `{usuário}` cru |

**Sala** — `{id, name, frequency_hz, invite_code, created_by, members:[{id,
display_name, role, joined_at}], created_at}`.

**Mensagem** — exatamente os campos da seção 6.3 da spec, nos três lugares.
`audio_url` é absoluto e já aponta para o IP da LAN.

**WebSocket** — verificado ponta a ponta com um cliente cru:

1. `ws://192.168.15.112:8080/app/flycomm-local-key?protocol=7&client=…&version=…`
2. o servidor manda `pusher:connection_established` com `socket_id`
3. `POST /broadcasting/auth` com `Authorization: Bearer <token>` e corpo
   `{socket_id, channel_name:"presence-room.255"}` → `{auth, channel_data}`
4. `pusher:subscribe` com esses dois campos → `pusher_internal:subscription_succeeded`
   trazendo `presence.hash` com `{id, display_name}` de cada membro
5. `message.new` chega com o metadado completo; `room.updated` traz
   `{id, name, frequency_hz}`

O canal no Laravel se chama `room.{id}`; **no fio o nome é `presence-room.{id}`**.

**Semântica de `window_start`** (lida do `CatchupController`): a resposta devolve
sempre `agora - catchup_window`, **não** o piso efetivo. É isso que torna a detecção
de buraco possível: houve buraco ⟺ `since != null && since < window_start`. Se o
campo devolvesse o piso efetivo, ele seria igual ao `since` sempre que `since` fosse
recente e o buraco nunca apareceria.

**Idempotência** (lida do `MessageController`): reenviar um `id` existente devolve
**200** com a mensagem gravada e **não** republica o evento; `id` de outra sala dá
**409**. Erro de validação dá **422** com JSON — há um `ForceJsonResponse` global.

### 0.1 Divergência de contrato encontrada — precisa de decisão antes da Tarefa 14

A seção 6.2.1 da spec diz que `format` é **`wav-pcm16-16k`** na Fase 2. O servidor
grava e devolve **`wav/pcm16/16000`** (`app/Console/Commands/DemoBurst.php:48` e
`database/factories/MessageFactory.php:24`).

Não quebra nada hoje: `StoreMessageRequest` valida `format` como `string|max:64`, e a
spec diz que o servidor trata áudio como bytes opacos. Mas são duas grafias do mesmo
formato circulando no mesmo sistema, e na Fase 3 — quando `format` passa a decidir
qual decodificador usar — vira bug.

**Este plano não escolhe por conta própria.** Ele envia `wav-pcm16-16k`, que é o que a
spec manda, e **não condiciona a reprodução ao valor de `format`** — o app da Fase 2
decodifica WAV sempre. Assim a rajada de demonstração do servidor toca normalmente e
nenhuma gambiarra de cliente é introduzida. A grafia canônica precisa ser decidida com
um commit no repo `flycomm`, propagado para os dois repos.

### 0.2 Interpretação assumida — janela de retentativa do upload

A spec diz "o upload tenta dentro da janela de validade e desiste" (2.1) sem dizer
qual orçamento é essa janela. Este plano usa **`playback_deadline_ms` contado a partir
de `captured_at`**: passado ele, ninguém tocaria o áudio de qualquer forma, então
insistir é gastar bateria e rádio por nada. Está isolado numa constante única
(`MessageUploader.validityWindow`) para trocar por `catchup_window_ms` numa linha, se
a calibragem em campo mostrar que preencher o histórico dos outros vale o custo.

---

## 1. Estrutura de arquivos

Os módulos são os quatro da seção 7 da spec. `ble/`, `bridge/` e `background/` são das
Fases 3 e 4 e **não** devem ser criados.

`GET /config`, o `server_time` e o desvio de relógio moram em `room/` porque são
coisas que vêm do servidor, e `room/` é o módulo que fala com o servidor.

```
lib/
├── main.dart                      ponto de entrada, sobe o AppScope
├── app.dart                       MaterialApp + roteamento entre as duas telas
├── env.dart                       base HTTP/WS via --dart-define
├── room/
│   ├── api_client.dart            dio, Bearer, 422 → ApiException
│   ├── server_clock.dart          desvio contra o relógio do servidor
│   ├── budgets.dart               modelo de GET /config
│   ├── config_repository.dart     GET /config, realimenta o ServerClock
│   ├── device_identity.dart       identifier/secret no armazenamento seguro
│   ├── auth_repository.dart       POST /auth/device, PATCH /me
│   ├── models.dart                Room, Member, RoomMessage, CatchupResult
│   ├── room_repository.dart       /rooms, join, leave, patch
│   ├── message_api.dart           POST messages, GET audio (com Range)
│   ├── catchup_repository.dart    GET catchup + detecção de buraco
│   ├── reverb_client.dart         presence channel, message.new, room.updated
│   └── message_uploader.dart      retentativa idempotente na janela de validade
├── audio/
│   ├── wav.dart                   cabeçalho RIFF PCM16
│   ├── segmenter.dart             corte de 5 s no metadado, nunca no áudio
│   ├── recorder.dart              record → PCM 16 kHz em stream → segmentos
│   ├── playback_queue.dart        FIFO estrito, prazo, meio-duplex
│   └── player.dart                just_audio, uma voz por vez
├── history/
│   ├── database.dart              drift: schema + conexão
│   ├── history_repository.dart    estados da mensagem, consultas da tela
│   └── audio_store.dart           arquivos de áudio no dispositivo
└── ui/
    ├── app_scope.dart             InheritedWidget com os controladores
    ├── rooms_screen.dart          minhas salas, entrar por código, criar
    ├── room_screen.dart           nome, frequência, membros, PTT, histórico
    ├── ptt_button.dart            botão de apertar e segurar
    └── message_tile.dart          uma linha do histórico com o estado

test/
├── room/server_clock_test.dart
├── room/budgets_test.dart
├── room/catchup_test.dart
├── room/message_uploader_test.dart
├── audio/wav_test.dart
├── audio/segmenter_test.dart
├── audio/playback_queue_test.dart
├── history/history_repository_test.dart
└── integration/                   contra o servidor real, sem mock
    ├── env.dart
    ├── config_test.dart
    ├── auth_test.dart
    ├── rooms_test.dart
    ├── messages_test.dart
    ├── catchup_test.dart
    └── reverb_test.dart
```

---

## 2. Como rodar os testes

Testes de unidade (Dart puro, sem servidor, sem emulador):

```bash
flutter test test/room test/audio test/history
```

Testes de integração (exigem o `flycomm-server` de pé). O IP muda de rede para rede,
então nunca é constante no código.

**Autentique uma vez por arquivo, com `setUpAll` e não `setUp`.** `setUp` roda antes
de *cada* teste; com cinco arquivos isso passa de 20 chamadas a `POST /auth/device`
numa suíte completa, e o `throttle:20,1` devolve 429 em testes que não têm defeito.
A exceção é `auth_test.dart`, cujo assunto é justamente autenticar.

**`-j 1` não é opcional.** `POST /auth/device` revoga o token anterior daquele
dispositivo, e os arquivos de teste compartilham as credenciais semeadas. Rodando em
paralelo — o padrão do `flutter test` — eles se deslogam mutuamente e você vê
`ApiException(401): Unauthenticated` em testes que não têm defeito nenhum:

```bash
flutter test test/integration \
  --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 \
  --dart-define=FLYCOMM_WS_HOST=192.168.15.112 \
  --dart-define=FLYCOMM_WS_PORT=8080 \
  --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Rodar o app:

```bash
flutter run --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Publicar uma rajada fresca para o app ter o que receber (os blobs expiram em 5 min):

```bash
cd ../flycomm-server && docker compose exec app php artisan flycomm:demo-burst 255 --from=510
```

---

## Tarefa 1: `flutter create` e esqueleto

Nada existe ainda. O diretório se chama `flycomm-app`, que não é nome válido de pacote
Dart (hífen), então `--project-name` é obrigatório.

**Escolhas:** pacote `flycomm`; identificador **`br.com.medeirostec.flycomm`**.
Plataformas só `android,ios`: a Fase 2 é um app de celular, e web/desktop só trariam
pastas para manter.

**Arquivos:**
- Criar: a árvore inteira do `flutter create` em `/Users/rodrigo/dev/flycomm-app`
- Modificar: `.gitignore`
- Remover: `test/widget_test.dart`

- [ ] **Passo 1: gerar o projeto no diretório atual**

```bash
cd /Users/rodrigo/dev/flycomm-app
flutter create --project-name flycomm --org br.com.medeirostec --platforms=android,ios --empty .
```

`--empty` evita o app de contador, que seria apagado no passo seguinte de qualquer
forma.

- [ ] **Passo 2: conferir o identificador**

```bash
grep -rn "br.com.medeirostec.flycomm" android/app/build.gradle.kts ios/Runner.xcodeproj/project.pbxproj | head -8
```

Esperado: `namespace` e `applicationId` no Gradle, e os `PRODUCT_BUNDLE_IDENTIFIER`
no projeto do Xcode. O `--org` já inclui `medeirostec`, então o nome do projeto
(`flycomm`) completa o identificador sem duplicar nada.

- [ ] **Passo 3: verificar que compila**

```bash
flutter analyze
```

Esperado: `No issues found!`

- [ ] **Passo 4: apagar o teste de exemplo e juntar o ignore do Flutter ao existente**

```bash
rm -f test/widget_test.dart
```

Acrescente ao fim de `.gitignore` (o `flutter create` já pode ter escrito parte
disso; não duplique linhas que já existam):

```gitignore
# Flutter/Dart
.dart_tool/
.flutter-plugins
.flutter-plugins-dependencies
build/
*.g.dart
ios/Pods/
ios/.symlinks/
ios/Flutter/Flutter.podspec
android/.gradle/
android/local.properties
```

> `*.g.dart` ignorado é uma decisão: o código gerado pelo `drift` é reprodutível com
> `build_runner`, e versioná-lo enche todo diff de ruído. A Tarefa 9 documenta o
> comando de regeneração.

- [ ] **Passo 5: commit**

```bash
git add -A
git commit -m "feat: flutter create do app da Fase 2 (br.com.flycomm)"
```

---

## Tarefa 2: dependências e configuração de plataforma

O app fala HTTP em claro com um IP da LAN e grava do microfone. As duas coisas são
bloqueadas por padrão nas duas plataformas, e descobrir isso depois de escrever a
camada de áudio é uma tarde perdida.

**Arquivos:**
- Modificar: `pubspec.yaml`
- Modificar: `android/app/src/main/AndroidManifest.xml`
- Modificar: `android/app/build.gradle.kts`
- Modificar: `ios/Runner/Info.plist`

- [ ] **Passo 1: declarar as dependências**

Substitua os blocos `dependencies:` e `dev_dependencies:` de `pubspec.yaml` por:

```yaml
dependencies:
  flutter:
    sdk: flutter
  dio: ^5.11.1
  drift: ^2.35.0
  drift_flutter: ^0.3.1
  flutter_secure_storage: ^11.1.1
  just_audio: ^0.10.6
  path_provider: ^2.1.6
  permission_handler: ^12.0.3
  record: ^7.1.1
  uuid: ^4.6.0
  web_socket_channel: ^3.0.3

dev_dependencies:
  flutter_test:
    sdk: flutter
  build_runner: ^2.16.1
  drift_dev: ^2.35.0
  flutter_lints: ^6.0.0
```

> **`permission_handler` fica na linha 12.x de propósito.** A 13.x exige
> `compileSdk 37`; o Flutter 3.47 compila contra 36 e o Android Gradle Plugin 9.1.0
> tem 36 como máximo recomendado. Com a 13.x o `flutter analyze` e os testes passam e
> só o **build** quebra, em `:app:checkDebugAarMetadata` — um modo de falha que não
> aparece até alguém tentar rodar no aparelho.

- [ ] **Passo 2: baixar e conferir que resolve**

```bash
flutter pub get
```

Esperado: `Got dependencies!` sem conflito de versão.

- [ ] **Passo 2b: confirmar que o projeto compila de verdade**

```bash
flutter build apk --debug --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Esperado: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

Faça isto agora, e não só no fim: `flutter analyze` limpo **não** prova que o app
monta. Incompatibilidade de SDK entre plugins só aparece no Gradle.

- [ ] **Passo 3: permissões e HTTP em claro no Android**

Em `android/app/src/main/AndroidManifest.xml`, acrescente antes de `<application`:

```xml
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.INTERNET"/>
```

e acrescente ao atributo da tag `<application`:

```xml
        android:usesCleartextTraffic="true"
```

> `usesCleartextTraffic` é **de desenvolvimento**: o backend de bancada é `http://`
> num IP da LAN. Antes de qualquer build de loja isso volta a `false` e o servidor
> ganha TLS.

- [ ] **Passo 4: minSdk do `record`**

Em `android/app/build.gradle.kts`, dentro de `defaultConfig`, troque a linha do
`minSdk` por:

```kotlin
        minSdk = 23
```

- [ ] **Passo 5: microfone e ATS no iOS**

Em `ios/Runner/Info.plist`, acrescente antes de `</dict>`:

```xml
	<key>NSMicrophoneUsageDescription</key>
	<string>O flycomm usa o microfone para transmitir sua voz para a sala de pilotos.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
```

> Mesma ressalva: ATS aberto é de bancada. Os dois booleanos juntos são a receita
> documentada pela Apple — sistemas modernos ignoram `NSAllowsArbitraryLoads` e
> honram `NSAllowsLocalNetworking`, e os antigos fazem o contrário.

- [ ] **Passo 6: verificar**

```bash
flutter analyze
```

Esperado: `No issues found!`

- [ ] **Passo 7: commit**

```bash
git add -A
git commit -m "feat: dependências da Fase 2 e permissões de microfone e rede local"
```

---

## Tarefa 3: ambiente por `--dart-define`

O IP do backend muda de rede para rede. Constante no código significa recompilar para
testar em outra rede, e um valor esquecido num commit.

**Arquivos:**
- Criar: `lib/env.dart`
- Criar: `test/integration/env.dart`

- [ ] **Passo 1: escrever `lib/env.dart`**

```dart
/// Endereços do backend. Vêm de --dart-define porque o IP da LAN muda de rede
/// para rede; nenhum deles tem padrão útil, e falhar cedo e alto é melhor que
/// bater num localhost que não existe dentro do emulador.
class Env {
  const Env._();

  static const httpBase = String.fromEnvironment('FLYCOMM_HTTP');
  static const wsHost = String.fromEnvironment('FLYCOMM_WS_HOST');
  static const wsPort = int.fromEnvironment('FLYCOMM_WS_PORT', defaultValue: 8080);
  static const wsKey = String.fromEnvironment('FLYCOMM_WS_KEY');

  /// Chame no arranque: um --dart-define esquecido vira uma falha imediata e
  /// legível, não um timeout de trinta segundos numa tela em branco.
  static void assertConfigured() {
    final missing = <String>[
      if (httpBase.isEmpty) 'FLYCOMM_HTTP',
      if (wsHost.isEmpty) 'FLYCOMM_WS_HOST',
      if (wsKey.isEmpty) 'FLYCOMM_WS_KEY',
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'Faltam --dart-define: ${missing.join(', ')}. '
        'Veja docs/superpowers/plans/2026-09-13-fase-2-app-flutter.md, seção 2.',
      );
    }
  }
}
```

- [ ] **Passo 2: escrever `test/integration/env.dart`**

```dart
import 'package:flycomm/env.dart';

/// Credenciais semeadas pelo servidor. Cada uma vira um token novo e revoga o
/// anterior daquele dispositivo, então dois testes concorrentes não podem
/// compartilhar o mesmo identifier.
const seededDevices = <String, ({String identifier, String secret, String name})>{
  'rodrigo': (
    identifier: 'demo-device-rodrigo-0001',
    secret: 'demo-secret-rodrigo-000000000000000000',
    name: 'Rodrigo',
  ),
  'marina': (
    identifier: 'demo-device-marina-0002',
    secret: 'demo-secret-marina-0000000000000000000',
    name: 'Marina',
  ),
  'tiago': (
    identifier: 'demo-device-tiago-0003',
    secret: 'demo-secret-tiago-00000000000000000000',
    name: 'Tiago',
  ),
};

const seededInviteCodes = ['FLY-TEST', 'FLY-2FLY'];

String get httpBase {
  Env.assertConfigured();
  return Env.httpBase;
}
```

- [ ] **Passo 3: verificar**

```bash
flutter analyze
```

Esperado: `No issues found!`

- [ ] **Passo 4: commit**

```bash
git add lib/env.dart test/integration/env.dart
git commit -m "feat: endereços do backend por --dart-define"
```

---

## Tarefa 4: `ServerClock` — frescor contra o relógio do servidor

A invariante mais fácil de violar sem perceber: comparar `created_at` com
`DateTime.now()` funciona na bancada e falha em campo, porque relógio de celular
deriva. Um device adiantado descarta mensagens boas; um atrasado toca mensagens
vencidas.

**Arquivos:**
- Criar: `lib/room/server_clock.dart`
- Testar: `test/room/server_clock_test.dart`

- [ ] **Passo 1: escrever o teste que falha**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/server_clock.dart';

void main() {
  test('sem sincronizar, não finge saber a hora do servidor', () {
    final clock = ServerClock(localNow: () => DateTime.utc(2026, 9, 13, 12));
    expect(clock.isSynced, isFalse);
  });

  test('a idade é medida contra o relógio do servidor, não o local', () {
    // O celular está 90 s ADIANTADO em relação ao servidor.
    final localNow = DateTime.utc(2026, 9, 13, 12, 0, 0);
    final clock = ServerClock(localNow: () => localNow);

    clock.sync(
      serverTime: DateTime.utc(2026, 9, 13, 11, 58, 30),
      receivedAt: localNow,
    );

    expect(clock.isSynced, isTrue);
    expect(clock.now(), DateTime.utc(2026, 9, 13, 11, 58, 30));

    // Mensagem criada 10 s atrás pelo relógio do SERVIDOR.
    final createdAt = DateTime.utc(2026, 9, 13, 11, 58, 20);

    // Contra o relógio do servidor: 10 s, fresca.
    expect(clock.ageOf(createdAt), const Duration(seconds: 10));
    // Contra o relógio local seriam 100 s, e ela teria sido descartada à toa.
    expect(localNow.difference(createdAt), const Duration(seconds: 100));
  });

  test('o relógio local andando move o relógio do servidor junto', () {
    var fake = DateTime.utc(2026, 9, 13, 12, 0, 0);
    final clock = ServerClock(localNow: () => fake);
    clock.sync(
      serverTime: DateTime.utc(2026, 9, 13, 11, 58, 30),
      receivedAt: fake,
    );

    fake = fake.add(const Duration(seconds: 5));

    expect(clock.now(), DateTime.utc(2026, 9, 13, 11, 58, 35));
  });

  test('sincronizar de novo substitui o desvio, não acumula', () {
    var fake = DateTime.utc(2026, 9, 13, 12, 0, 0);
    final clock = ServerClock(localNow: () => fake);

    clock.sync(serverTime: DateTime.utc(2026, 9, 13, 11, 58, 30), receivedAt: fake);
    clock.sync(serverTime: DateTime.utc(2026, 9, 13, 12, 0, 2), receivedAt: fake);

    expect(clock.now(), DateTime.utc(2026, 9, 13, 12, 0, 2));
  });
}
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
flutter test test/room/server_clock_test.dart
```

Esperado: FALHA com `Target of URI doesn't exist: 'package:flycomm/room/server_clock.dart'`.

- [ ] **Passo 3: escrever a implementação mínima**

```dart
/// O relógio contra o qual toda idade é medida.
///
/// Relógio de celular deriva. Comparar `created_at` com DateTime.now() funciona
/// na bancada e falha em campo: um aparelho adiantado descarta mensagens boas,
/// um atrasado toca mensagens vencidas. O desvio sai do campo `server_time` que
/// GET /config e GET /rooms/{id}/catchup devolvem, e é reaplicado a cada
/// resposta — é de graça e corrige deriva ao longo do voo.
class ServerClock {
  ServerClock({DateTime Function()? localNow})
      : _localNow = localNow ?? (() => DateTime.now().toUtc());

  final DateTime Function() _localNow;

  Duration _skew = Duration.zero;
  bool _synced = false;

  bool get isSynced => _synced;
  Duration get skew => _skew;

  /// [receivedAt] é o relógio local no instante em que a resposta chegou — o
  /// mesmo instante a que [serverTime] se refere, a menos da metade do
  /// round-trip, que numa LAN é ruído comparado ao prazo de 30 s.
  void sync({required DateTime serverTime, required DateTime receivedAt}) {
    _skew = serverTime.toUtc().difference(receivedAt.toUtc());
    _synced = true;
  }

  DateTime now() => _localNow().toUtc().add(_skew);

  Duration ageOf(DateTime createdAt) => now().difference(createdAt.toUtc());
}
```

- [ ] **Passo 4: rodar e ver passar**

```bash
flutter test test/room/server_clock_test.dart
```

Esperado: `All tests passed!` (4 testes)

- [ ] **Passo 5: commit**

```bash
git add lib/room/server_clock.dart test/room/server_clock_test.dart
git commit -m "feat: ServerClock, frescor medido contra o relógio do servidor"
```

---

## Tarefa 5: `Budgets` — os orçamentos vêm de `GET /config`

Os cinco números da seção 2 da spec são configuração do servidor, não constante de
código: são chutes a calibrar em campo, e calibrar não pode depender de publicar
versão na loja.

**Arquivos:**
- Criar: `lib/room/budgets.dart`
- Testar: `test/room/budgets_test.dart`

- [ ] **Passo 1: escrever o teste que falha**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/budgets.dart';

void main() {
  // Corpo real de GET /config, copiado da resposta do servidor.
  const payload = {
    'budgets': {
      'playback_deadline_ms': 30000,
      'radio_relay_deadline_ms': 10000,
      'segment_max_ms': 5000,
      'catchup_window_ms': 60000,
      'blob_ttl_ms': 300000,
    },
    'frequency_bands': [
      {'min_hz': 136000000, 'max_hz': 174000000},
      {'min_hz': 400000000, 'max_hz': 470000000},
    ],
    'server_time': '2026-09-13T16:02:13.690074Z',
  };

  test('lê os cinco orçamentos como Duration', () {
    final config = ServerConfig.fromJson(payload);

    expect(config.budgets.playbackDeadline, const Duration(seconds: 30));
    expect(config.budgets.radioRelayDeadline, const Duration(seconds: 10));
    expect(config.budgets.segmentMax, const Duration(seconds: 5));
    expect(config.budgets.catchupWindow, const Duration(seconds: 60));
    expect(config.budgets.blobTtl, const Duration(minutes: 5));
  });

  test('server_time vira DateTime em UTC, com microssegundos', () {
    final config = ServerConfig.fromJson(payload);

    expect(config.serverTime.isUtc, isTrue);
    expect(config.serverTime.microsecondsSinceEpoch % 1000, 74);
  });

  test('as faixas de rádio validam frequência em Hz inteiro', () {
    final config = ServerConfig.fromJson(payload);

    expect(config.isFrequencyValid(145550000), isTrue);
    expect(config.isFrequencyValid(446000000), isTrue);
    expect(config.isFrequencyValid(200000000), isFalse);
    expect(config.isFrequencyValid(135999999), isFalse);
    expect(config.isFrequencyValid(174000000), isTrue);
  });
}
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
flutter test test/room/budgets_test.dart
```

Esperado: FALHA com `Target of URI doesn't exist: 'package:flycomm/room/budgets.dart'`.

- [ ] **Passo 3: escrever a implementação mínima**

```dart
/// Os orçamentos de tempo da seção 2 da spec.
///
/// Chegam de GET /config e nunca são constantes no código: os valores são
/// chutes a calibrar em campo, e calibrar não pode depender da loja.
class Budgets {
  const Budgets({
    required this.playbackDeadline,
    required this.radioRelayDeadline,
    required this.segmentMax,
    required this.catchupWindow,
    required this.blobTtl,
  });

  final Duration playbackDeadline;
  final Duration radioRelayDeadline;
  final Duration segmentMax;
  final Duration catchupWindow;
  final Duration blobTtl;

  factory Budgets.fromJson(Map<String, dynamic> json) => Budgets(
        playbackDeadline: Duration(milliseconds: json['playback_deadline_ms'] as int),
        radioRelayDeadline: Duration(milliseconds: json['radio_relay_deadline_ms'] as int),
        segmentMax: Duration(milliseconds: json['segment_max_ms'] as int),
        catchupWindow: Duration(milliseconds: json['catchup_window_ms'] as int),
        blobTtl: Duration(milliseconds: json['blob_ttl_ms'] as int),
      );
}

class FrequencyBand {
  const FrequencyBand({required this.minHz, required this.maxHz});

  final int minHz;
  final int maxHz;

  bool contains(int hz) => hz >= minHz && hz <= maxHz;

  factory FrequencyBand.fromJson(Map<String, dynamic> json) => FrequencyBand(
        minHz: json['min_hz'] as int,
        maxHz: json['max_hz'] as int,
      );
}

class ServerConfig {
  const ServerConfig({
    required this.budgets,
    required this.frequencyBands,
    required this.serverTime,
  });

  final Budgets budgets;
  final List<FrequencyBand> frequencyBands;
  final DateTime serverTime;

  /// Frequência é inteiro em Hz, nunca float: comparar 145.55 MHz em ponto
  /// flutuante é convidar erro de arredondamento numa checagem de faixa.
  bool isFrequencyValid(int hz) =>
      frequencyBands.any((band) => band.contains(hz));

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        budgets: Budgets.fromJson(json['budgets'] as Map<String, dynamic>),
        frequencyBands: (json['frequency_bands'] as List<dynamic>)
            .map((e) => FrequencyBand.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        serverTime: DateTime.parse(json['server_time'] as String).toUtc(),
      );
}
```

- [ ] **Passo 4: rodar e ver passar**

```bash
flutter test test/room/budgets_test.dart
```

Esperado: `All tests passed!` (3 testes)

- [ ] **Passo 5: commit**

```bash
git add lib/room/budgets.dart test/room/budgets_test.dart
git commit -m "feat: modelo dos orçamentos de GET /config"
```

---

## Tarefa 6: `ApiClient` e `ConfigRepository`

Uma borda HTTP só, para que o 422 vire exceção legível num lugar e o `server_time` de
toda resposta realimente o `ServerClock` sem ninguém precisar lembrar.

**Arquivos:**
- Criar: `lib/room/api_client.dart`
- Criar: `lib/room/config_repository.dart`
- Testar: `test/integration/config_test.dart`

- [ ] **Passo 1: escrever `lib/room/api_client.dart`**

```dart
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
```

- [ ] **Passo 2: escrever `lib/room/config_repository.dart`**

```dart
import 'api_client.dart';
import 'budgets.dart';
import 'server_clock.dart';

/// GET /config é a única rota autenticada por ninguém além de POST /auth/device:
/// não carrega segredo e precisa ser legível antes do primeiro login, porque é
/// dela que saem os orçamentos.
class ConfigRepository {
  ConfigRepository({required this.api, required this.clock});

  final ApiClient api;
  final ServerClock clock;

  Future<ServerConfig> fetch() async {
    final response = await api.send<Map<String, dynamic>>('GET', '/config');
    final receivedAt = DateTime.now().toUtc();

    final config = ServerConfig.fromJson(response.data!);
    clock.sync(serverTime: config.serverTime, receivedAt: receivedAt);

    return config;
  }
}
```

- [ ] **Passo 3: escrever o teste de integração contra o servidor real**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/config_repository.dart';
import 'package:flycomm/room/server_clock.dart';

import 'env.dart';

void main() {
  late ConfigRepository repo;
  late ServerClock clock;

  setUp(() {
    clock = ServerClock();
    repo = ConfigRepository(
      api: ApiClient(baseUrl: httpBase),
      clock: clock,
    );
  });

  test('GET /config devolve os cinco orçamentos e as duas faixas', () async {
    final config = await repo.fetch();

    expect(config.budgets.segmentMax, const Duration(seconds: 5));
    expect(config.budgets.playbackDeadline.inMilliseconds, greaterThan(0));
    expect(config.budgets.catchupWindow, greaterThan(config.budgets.playbackDeadline),
        reason: 'a janela de catch-up é maior que o prazo de propósito: o '
            'excedente não toca, mas preenche o histórico (spec 2.1)');
    expect(config.frequencyBands, hasLength(2));
    expect(config.isFrequencyValid(145550000), isTrue);
  });

  test('GET /config sincroniza o relógio com desvio pequeno numa LAN', () async {
    await repo.fetch();

    expect(clock.isSynced, isTrue);
    expect(clock.skew.abs(), lessThan(const Duration(seconds: 5)),
        reason: 'servidor e Mac de bancada não deveriam divergir muito; se '
            'divergirem, o relógio de um dos dois está errado');
  });
}
```

- [ ] **Passo 4: rodar contra o servidor de pé**

```bash
flutter test -j 1 test/integration/config_test.dart --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Esperado: `All tests passed!` (2 testes). Se der `Connection refused`, o backend não
está de pé: `cd ../flycomm-server && docker compose up -d`.

- [ ] **Passo 5: commit**

```bash
git add lib/room/api_client.dart lib/room/config_repository.dart test/integration/config_test.dart
git commit -m "feat: cliente HTTP e GET /config sincronizando o relógio"
```

---

## Tarefa 7: identidade de dispositivo e `POST /auth/device`

A identidade é o `user`; a credencial é um anexo. No primeiro uso o app gera um
segredo, guarda no armazenamento seguro da plataforma e troca por um token Sanctum.

**Arquivos:**
- Criar: `lib/room/device_identity.dart`
- Criar: `lib/room/auth_repository.dart`
- Testar: `test/integration/auth_test.dart`

- [ ] **Passo 1: escrever `lib/room/device_identity.dart`**

```dart
import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Credencial do tipo `device`: o app gera o par uma vez e o guarda no
/// armazenamento seguro da plataforma.
///
/// A dívida é conhecida e aceita: trocou de celular, perdeu tudo. Ela existe
/// porque reivindicar a conta depois é inserir uma linha em `credentials`
/// apontando para o mesmo user_id — não uma migração de `users`.
class DeviceCredentials {
  const DeviceCredentials({required this.identifier, required this.secret});

  final String identifier;
  final String secret;
}

class DeviceIdentity {
  DeviceIdentity({FlutterSecureStorage? storage, Random? random})
      : _storage = storage ?? const FlutterSecureStorage(),
        _random = random ?? Random.secure();

  static const _identifierKey = 'flycomm.device.identifier';
  static const _secretKey = 'flycomm.device.secret';

  final FlutterSecureStorage _storage;
  final Random _random;

  Future<DeviceCredentials> loadOrCreate() async {
    final existingId = await _storage.read(key: _identifierKey);
    final existingSecret = await _storage.read(key: _secretKey);

    if (existingId != null && existingSecret != null) {
      return DeviceCredentials(identifier: existingId, secret: existingSecret);
    }

    final created = _generate();
    await _storage.write(key: _identifierKey, value: created.identifier);
    await _storage.write(key: _secretKey, value: created.secret);
    return created;
  }

  /// identifier: 'flycomm-' + 32 hex = 40 caracteres, dentro de 16–128.
  /// secret: 48 bytes em base64url = 64 caracteres, dentro de 32–72.
  ///
  /// O teto de 72 é o do bcrypt: acima disso o algoritmo trunca em silêncio e
  /// dois segredos diferentes viram o mesmo.
  DeviceCredentials _generate() {
    String hex(int bytes) => List.generate(
          bytes,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();

    final secretBytes = List<int>.generate(48, (_) => _random.nextInt(256));

    return DeviceCredentials(
      identifier: 'flycomm-${hex(16)}',
      secret: base64Url.encode(secretBytes),
    );
  }
}
```

- [ ] **Passo 2: escrever `lib/room/auth_repository.dart`**

```dart
import 'api_client.dart';
import 'device_identity.dart';

class AuthenticatedUser {
  const AuthenticatedUser({required this.id, required this.displayName});

  final int id;
  final String displayName;

  factory AuthenticatedUser.fromJson(Map<String, dynamic> json) =>
      AuthenticatedUser(
        id: json['id'] as int,
        displayName: json['display_name'] as String,
      );
}

class AuthRepository {
  AuthRepository({required this.api});

  final ApiClient api;

  /// Cria ou recupera o usuário. O display_name só vale na criação — numa
  /// recuperação o servidor o ignora, porque o nome canônico vive lá e quem o
  /// muda é PATCH /me.
  ///
  /// Cada chamada emite um token novo e revoga o anterior daquele dispositivo:
  /// chamar isto "por via das dúvidas" derruba a própria sessão.
  Future<AuthenticatedUser> authenticate(
    DeviceCredentials credentials, {
    required String displayName,
  }) async {
    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/auth/device',
      data: {
        'identifier': credentials.identifier,
        'secret': credentials.secret,
        'display_name': displayName,
      },
    );

    final body = response.data!;
    api.token = body['token'] as String;

    return AuthenticatedUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  Future<AuthenticatedUser> updateDisplayName(String displayName) async {
    final response = await api.send<Map<String, dynamic>>(
      'PATCH',
      '/me',
      data: {'display_name': displayName},
    );

    return AuthenticatedUser.fromJson(response.data!);
  }
}
```

- [ ] **Passo 3: escrever o teste de integração**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/device_identity.dart';

import 'env.dart';

void main() {
  late ApiClient api;
  late AuthRepository auth;

  setUp(() {
    api = ApiClient(baseUrl: httpBase);
    auth = AuthRepository(api: api);
  });

  test('autentica com um device semeado e recebe token', () async {
    final seeded = seededDevices['rodrigo']!;

    final user = await auth.authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );

    expect(user.id, greaterThan(0));
    expect(user.displayName, seeded.name);
    expect(api.token, isNotEmpty);
  });

  test('recuperação ignora o display_name enviado', () async {
    final seeded = seededDevices['tiago']!;
    final credentials =
        DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret);

    final first = await auth.authenticate(credentials, displayName: seeded.name);
    final second =
        await auth.authenticate(credentials, displayName: 'Nome Descartado');

    expect(second.id, first.id, reason: 'mesma credencial, mesmo usuário');
    expect(second.displayName, seeded.name,
        reason: 'o nome canônico vive no servidor; quem o muda é PATCH /me');
  });

  test('identifier e secret gerados cabem nos limites do servidor', () async {
    final generated = await DeviceIdentity(storage: _MemoryStorage()).loadOrCreate();

    expect(generated.identifier.length, inInclusiveRange(16, 128));
    expect(generated.secret.length, inInclusiveRange(32, 72),
        reason: 'o teto de 72 é o do bcrypt: acima disso ele trunca em silêncio');

    final user = await auth.authenticate(generated, displayName: 'Device Novo');
    expect(user.displayName, 'Device Novo');
  });

  test('segredo errado é recusado', () async {
    final seeded = seededDevices['marina']!;

    await expectLater(
      auth.authenticate(
        DeviceCredentials(
          identifier: seeded.identifier,
          secret: 'errado-mas-com-tamanho-suficiente-para-passar-na-validacao',
        ),
        displayName: seeded.name,
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
```

O teste do par gerado precisa de um armazenamento que funcione no host, onde não há
Keychain nem Keystore. Acrescente ao fim do mesmo arquivo:

```dart
/// FlutterSecureStorage não funciona em `flutter test` (não há plataforma).
/// Este duplo guarda em memória, que é tudo que o teste precisa.
class _MemoryStorage implements FlutterSecureStorage {
  final _values = <String, String>{};

  @override
  Future<String?> read({required String key, other}) async => _values[key];

  @override
  Future<void> write({required String key, required String? value, other}) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
```

E acrescente o import no topo do arquivo de teste:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
```

> Se `noSuchMethod` reclamar de membros não implementados, marque a classe com
> `// ignore: subtype_of_sealed_class` ou troque por um `Mock` do `mocktail`. O
> objetivo do teste é só o formato do par gerado.

- [ ] **Passo 4: rodar**

```bash
flutter test -j 1 test/integration/auth_test.dart --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Esperado: `All tests passed!` (4 testes).

> Se der **429**, o `throttle:20,1` de `POST /auth/device` estourou. Espere um
> minuto. Isso é um motivo real para não rodar a suíte de integração em laço.

- [ ] **Passo 5: commit**

```bash
git add lib/room/device_identity.dart lib/room/auth_repository.dart test/integration/auth_test.dart
git commit -m "feat: identidade de dispositivo e POST /auth/device"
```

---

## Tarefa 8: modelos e `RoomRepository`

Mensagem tem um formato só, nos três lugares onde aparece — evento, resposta do upload
e catch-up. Uma classe só, portanto.

**Arquivos:**
- Criar: `lib/room/models.dart`
- Criar: `lib/room/room_repository.dart`
- Testar: `test/integration/rooms_test.dart`

- [ ] **Passo 1: escrever `lib/room/models.dart`**

```dart
class Member {
  const Member({
    required this.id,
    required this.displayName,
    required this.role,
    this.joinedAt,
  });

  final int id;
  final String displayName;
  final String role;
  final DateTime? joinedAt;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
        id: json['id'] as int,
        displayName: json['display_name'] as String,
        // O vínculo já nasce com role, todos `member`, ninguém checando nada:
        // quando o modelo de papéis chegar, é escrever policies, não migrar.
        role: (json['role'] as String?) ?? 'member',
        joinedAt: json['joined_at'] == null
            ? null
            : DateTime.parse(json['joined_at'] as String).toUtc(),
      );
}

class Room {
  const Room({
    required this.id,
    required this.name,
    required this.frequencyHz,
    required this.inviteCode,
    required this.createdBy,
    required this.members,
  });

  final int id;
  final String name;

  /// Inteiro em Hz, nullable. Nullable descreve com honestidade o estado
  /// "ainda não combinamos a frequência", que continua real depois da Fase 3.
  final int? frequencyHz;
  final String inviteCode;
  final int createdBy;
  final List<Member> members;

  Room copyWith({String? name, int? frequencyHz, bool clearFrequency = false}) =>
      Room(
        id: id,
        name: name ?? this.name,
        frequencyHz: clearFrequency ? null : (frequencyHz ?? this.frequencyHz),
        inviteCode: inviteCode,
        createdBy: createdBy,
        members: members,
      );

  factory Room.fromJson(Map<String, dynamic> json) => Room(
        id: json['id'] as int,
        name: json['name'] as String,
        frequencyHz: json['frequency_hz'] as int?,
        inviteCode: json['invite_code'] as String,
        createdBy: json['created_by'] as int,
        members: ((json['members'] as List<dynamic>?) ?? const [])
            .map((e) => Member.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// O metadado de uma mensagem, idêntico nos três lugares onde ela aparece:
/// o evento `message.new`, a resposta de POST /rooms/{id}/messages e o
/// catch-up. Três definições divergiriam justamente onde o app precisa tratar
/// as três como a mesma coisa.
class RoomMessage {
  const RoomMessage({
    required this.id,
    required this.roomId,
    required this.burstId,
    required this.index,
    required this.authorId,
    required this.authorName,
    required this.durationMs,
    required this.origin,
    required this.format,
    required this.sizeBytes,
    required this.capturedAt,
    required this.createdAt,
    required this.expiresAt,
    required this.audioUrl,
  });

  final String id;
  final int roomId;
  final String burstId;
  final int index;

  /// Nulos quando `origin` é `radio`: quem só tem rádio não é membro da sala e
  /// não há como identificá-lo a partir do áudio.
  final int? authorId;
  final String? authorName;

  final int durationMs;
  final String origin;
  final String format;
  final int sizeBytes;
  final DateTime? capturedAt;

  /// A autoridade de frescor. É contra este carimbo — emitido pelo servidor —
  /// que a idade é medida, nunca contra `capturedAt`, que é do cliente.
  final DateTime createdAt;

  final DateTime expiresAt;
  final String audioUrl;

  factory RoomMessage.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>?;

    return RoomMessage(
      id: json['id'] as String,
      roomId: json['room_id'] as int,
      burstId: json['burst_id'] as String,
      index: json['index'] as int,
      authorId: user?['id'] as int?,
      authorName: user?['display_name'] as String?,
      durationMs: json['duration_ms'] as int,
      origin: json['origin'] as String,
      format: json['format'] as String,
      sizeBytes: json['size_bytes'] as int,
      capturedAt: json['captured_at'] == null
          ? null
          : DateTime.parse(json['captured_at'] as String).toUtc(),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      audioUrl: json['audio_url'] as String,
    );
  }
}
```

- [ ] **Passo 2: escrever `lib/room/room_repository.dart`**

```dart
import 'api_client.dart';
import 'models.dart';

class RoomRepository {
  RoomRepository({required this.api});

  final ApiClient api;

  /// A única rota que embrulha em `data`.
  Future<List<Room>> mine() async {
    final response = await api.send<Map<String, dynamic>>('GET', '/rooms');

    return (response.data!['data'] as List<dynamic>)
        .map((e) => Room.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<Room> create({required String name, int? frequencyHz}) async {
    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/rooms',
      data: {
        'name': name,
        if (frequencyHz != null) 'frequency_hz': frequencyHz,
      },
    );

    return Room.fromJson(response.data!);
  }

  /// O servidor normaliza: aceita minúscula, com ou sem hífen, com ou sem FLY.
  Future<Room> join(String inviteCode) async {
    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/rooms/join',
      data: {'invite_code': inviteCode},
    );

    return Room.fromJson(response.data!);
  }

  /// A sala é plana: qualquer membro renomeia e muda a frequência. Enviar
  /// `frequency_hz: null` explicitamente limpa a frequência, e é por isso que
  /// `clearFrequency` existe separado de simplesmente omitir o campo.
  Future<Room> update(
    int roomId, {
    String? name,
    int? frequencyHz,
    bool clearFrequency = false,
  }) async {
    final response = await api.send<Map<String, dynamic>>(
      'PATCH',
      '/rooms/$roomId',
      data: {
        if (name != null) 'name': name,
        if (clearFrequency) 'frequency_hz': null
        else if (frequencyHz != null) 'frequency_hz': frequencyHz,
      },
    );

    return Room.fromJson(response.data!);
  }

  Future<void> leave(int roomId) =>
      api.send<void>('POST', '/rooms/$roomId/leave');
}
```

- [ ] **Passo 3: escrever o teste de integração**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/device_identity.dart';
import 'package:flycomm/room/room_repository.dart';

import 'env.dart';

void main() {
  late RoomRepository rooms;

  setUp(() async {
    final api = ApiClient(baseUrl: httpBase);
    final seeded = seededDevices['rodrigo']!;
    await AuthRepository(api: api).authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );
    rooms = RoomRepository(api: api);
  });

  test('entra por código e enxerga os membros', () async {
    final room = await rooms.join('FLY-TEST');

    expect(room.inviteCode, 'FLY-TEST');
    expect(room.members.length, greaterThanOrEqualTo(1));
    expect(room.members.every((m) => m.role == 'member'), isTrue);
  });

  test('o código é normalizado: minúscula, sem hífen, sem prefixo', () async {
    final canonical = await rooms.join('FLY-TEST');

    for (final variant in ['fly-test', 'FLYTEST', 'test', 'Test']) {
      final room = await rooms.join(variant);
      expect(room.id, canonical.id, reason: '"$variant" deveria cair na mesma sala');
    }
  });

  test('minhas salas vêm embrulhadas em data', () async {
    await rooms.join('FLY-TEST');
    final mine = await rooms.mine();

    expect(mine, isNotEmpty);
    expect(mine.map((r) => r.inviteCode), contains('FLY-TEST'));
  });

  test('frequência é inteiro em Hz e pode ser limpa', () async {
    final created = await rooms.create(name: 'Sala de teste', frequencyHz: 145550000);
    expect(created.frequencyHz, 145550000);

    final cleared = await rooms.update(created.id, clearFrequency: true);
    expect(cleared.frequencyHz, isNull,
        reason: 'nullable descreve "ainda não combinamos a frequência"');

    final retuned = await rooms.update(created.id, frequencyHz: 446000000);
    expect(retuned.frequencyHz, 446000000);
  });

  test('frequência fora das faixas do rádio é recusada com 422', () async {
    await expectLater(
      rooms.create(name: 'Fora de faixa', frequencyHz: 200000000),
      throwsA(isA<ApiException>().having((e) => e.isValidation, 'isValidation', isTrue)),
    );
  });

  test('qualquer membro renomeia: a sala é plana', () async {
    final room = await rooms.join('FLY-TEST');
    final renamed = await rooms.update(room.id, name: 'Voo de domingo');

    expect(renamed.name, 'Voo de domingo');
  });
}
```

- [ ] **Passo 4: rodar**

```bash
flutter test -j 1 test/integration/rooms_test.dart --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Esperado: `All tests passed!` (6 testes).

- [ ] **Passo 5: commit**

```bash
git add lib/room/models.dart lib/room/room_repository.dart test/integration/rooms_test.dart
git commit -m "feat: modelos de sala e mensagem e as rotas de sala"
```

---

## Tarefa 9: histórico local em SQLite

O histórico é 100% local e permanente. O servidor é transporte, não arquivo: não se
busca histórico antigo lá, ele não existe.

O schema do SQLite era questão em aberto na spec (seção 10) — aqui ela é fechada.

**Arquivos:**
- Criar: `lib/history/database.dart`
- Criar: `lib/history/history_repository.dart`
- Testar: `test/history/history_repository_test.dart`

- [ ] **Passo 1: escrever `lib/history/database.dart`**

```dart
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// O ciclo de vida de uma mensagem no histórico local.
///
/// Saída: gravada → enviando → entregue, ou → não entregue.
/// Entrada: recebida (tocada) ou atrasada (saiu da fila sem tocar, ouvível
/// por toque, nunca automaticamente).
enum MessageState {
  recorded,
  sending,
  delivered,
  undelivered,
  received,
  late,
}

enum MessageDirection { outgoing, incoming }

@DataClassName('LocalMessage')
class LocalMessages extends Table {
  /// uuid gerado pelo app na saída, id do servidor na entrada. É o mesmo id nos
  /// dois lados: é o que torna o upload idempotente.
  TextColumn get id => text()();

  IntColumn get roomId => integer()();
  TextColumn get burstId => text()();
  IntColumn get segmentIndex => integer().named('index')();

  IntColumn get authorId => integer().nullable()();
  TextColumn get authorName => text().nullable()();

  IntColumn get durationMs => integer()();
  TextColumn get origin => text()();
  TextColumn get format => text()();
  IntColumn get sizeBytes => integer().nullable()();

  /// Do cliente, só para o histórico.
  DateTimeColumn get capturedAt => dateTime().nullable()();

  /// Do servidor: a autoridade de frescor. Nulo enquanto a mensagem não foi
  /// aceita — uma mensagem não entregue nunca teve um `created_at`.
  DateTimeColumn get createdAt => dateTime().nullable()();

  TextColumn get direction => textEnum<MessageDirection>()();
  TextColumn get state => textEnum<MessageState>()();

  /// Caminho do arquivo no dispositivo. Nulo enquanto o download não terminou.
  TextColumn get audioPath => text().nullable()();

  /// Ordena o histórico mesmo quando createdAt é nulo.
  DateTimeColumn get recordedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [LocalMessages])
class HistoryDatabase extends _$HistoryDatabase {
  HistoryDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'flycomm_history'));

  @override
  int get schemaVersion => 1;
}
```

- [ ] **Passo 2: gerar o código do drift**

```bash
dart run build_runner build --delete-conflicting-outputs
```

Esperado: `Succeeded after …` e `lib/history/database.g.dart` criado.

> Sempre que `database.dart` mudar, rode este comando de novo. O `.g.dart` é
> ignorado pelo git de propósito (Tarefa 1, Passo 4).

- [ ] **Passo 3: escrever o teste que falha**

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/history/database.dart';
import 'package:flycomm/history/history_repository.dart';
import 'package:flycomm/room/models.dart';

void main() {
  late HistoryDatabase db;
  late HistoryRepository history;

  setUp(() {
    db = HistoryDatabase(NativeDatabase.memory());
    history = HistoryRepository(db);
  });

  tearDown(() => db.close());

  RoomMessage incoming(String id, {int index = 0, String burst = 'b-1'}) =>
      RoomMessage(
        id: id,
        roomId: 255,
        burstId: burst,
        index: index,
        authorId: 510,
        authorName: 'Marina',
        durationMs: 5000,
        origin: 'app',
        format: 'wav-pcm16-16k',
        sizeBytes: 160044,
        capturedAt: DateTime.utc(2026, 9, 13, 16),
        createdAt: DateTime.utc(2026, 9, 13, 16, 0, 1),
        expiresAt: DateTime.utc(2026, 9, 13, 16, 5, 1),
        audioUrl: 'http://servidor/messages/$id/audio',
      );

  test('a mensagem de saída percorre gravada → enviando → entregue', () async {
    await history.recordOutgoing(
      id: 'out-1',
      roomId: 255,
      burstId: 'b-out',
      index: 0,
      durationMs: 5000,
      format: 'wav-pcm16-16k',
      capturedAt: DateTime.utc(2026, 9, 13, 16),
      audioPath: '/tmp/out-1.wav',
    );
    expect((await history.byId('out-1'))!.state, MessageState.recorded);

    await history.markSending('out-1');
    expect((await history.byId('out-1'))!.state, MessageState.sending);

    await history.markDelivered('out-1', incoming('out-1'));
    final delivered = (await history.byId('out-1'))!;
    expect(delivered.state, MessageState.delivered);
    expect(delivered.createdAt, isNotNull,
        reason: 'só o servidor emite createdAt, e só quando aceita a mensagem');
  });

  test('a mensagem não entregue guarda o áudio e não ganha createdAt', () async {
    await history.recordOutgoing(
      id: 'out-2',
      roomId: 255,
      burstId: 'b-out',
      index: 0,
      durationMs: 3000,
      format: 'wav-pcm16-16k',
      capturedAt: DateTime.utc(2026, 9, 13, 16),
      audioPath: '/tmp/out-2.wav',
    );
    await history.markUndelivered('out-2');

    final row = (await history.byId('out-2'))!;
    expect(row.state, MessageState.undelivered);
    expect(row.createdAt, isNull);
    expect(row.audioPath, '/tmp/out-2.wav',
        reason: 'o áudio fica no dispositivo: o histórico é permanente mesmo '
            'quando ninguém ouviu');
  });

  test('gravar a mesma mensagem duas vezes não duplica', () async {
    await history.recordIncoming(incoming('in-1'), MessageState.received);
    await history.recordIncoming(incoming('in-1'), MessageState.received);

    expect(await history.countForRoom(255), 1);
  });

  test('mensagem que venceu na fila entra como atrasada', () async {
    await history.recordIncoming(incoming('in-2'), MessageState.late);

    expect((await history.byId('in-2'))!.state, MessageState.late);
  });

  test('o histórico da sala vem em ordem de rajada e índice', () async {
    await history.recordIncoming(incoming('s-2', index: 1), MessageState.received);
    await history.recordIncoming(incoming('s-1', index: 0), MessageState.received);
    await history.recordIncoming(incoming('s-3', index: 2), MessageState.received);

    final rows = await history.forRoom(255);

    expect(rows.map((r) => r.id), ['s-1', 's-2', 's-3'],
        reason: 'os três segmentos de uma fala de 12 s aparecem em ordem');
  });

  test('a última mensagem vista é o since do catch-up', () async {
    expect(await history.lastSeenAt(255), isNull);

    await history.recordIncoming(incoming('t-1'), MessageState.received);

    expect(await history.lastSeenAt(255), DateTime.utc(2026, 9, 13, 16, 0, 1));
  });
}
```

- [ ] **Passo 4: rodar e ver falhar**

```bash
flutter test test/history/history_repository_test.dart
```

Esperado: FALHA com `Target of URI doesn't exist: 'package:flycomm/history/history_repository.dart'`.

- [ ] **Passo 5: escrever `lib/history/history_repository.dart`**

```dart
import 'package:drift/drift.dart';

import '../room/models.dart';
import 'database.dart';

class HistoryRepository {
  HistoryRepository(this.db);

  final HistoryDatabase db;

  Future<void> recordOutgoing({
    required String id,
    required int roomId,
    required String burstId,
    required int index,
    required int durationMs,
    required String format,
    required DateTime capturedAt,
    required String audioPath,
  }) =>
      db.into(db.localMessages).insertOnConflictUpdate(
            LocalMessagesCompanion.insert(
              id: id,
              roomId: roomId,
              burstId: burstId,
              segmentIndex: index,
              durationMs: durationMs,
              origin: 'app',
              format: format,
              capturedAt: Value(capturedAt),
              direction: MessageDirection.outgoing,
              state: MessageState.recorded,
              audioPath: Value(audioPath),
              recordedAt: capturedAt,
            ),
          );

  Future<void> recordIncoming(RoomMessage message, MessageState state) =>
      db.into(db.localMessages).insertOnConflictUpdate(
            LocalMessagesCompanion.insert(
              id: message.id,
              roomId: message.roomId,
              burstId: message.burstId,
              segmentIndex: message.index,
              authorId: Value(message.authorId),
              authorName: Value(message.authorName),
              durationMs: message.durationMs,
              origin: message.origin,
              format: message.format,
              sizeBytes: Value(message.sizeBytes),
              capturedAt: Value(message.capturedAt),
              createdAt: Value(message.createdAt),
              direction: MessageDirection.incoming,
              state: state,
              recordedAt: message.createdAt,
            ),
          );

  Future<void> _setState(String id, MessageState state) =>
      (db.update(db.localMessages)..where((t) => t.id.equals(id)))
          .write(LocalMessagesCompanion(state: Value(state)));

  Future<void> markSending(String id) => _setState(id, MessageState.sending);

  Future<void> markUndelivered(String id) =>
      _setState(id, MessageState.undelivered);

  /// O servidor aceitou: agora a mensagem tem `created_at`, que é a autoridade
  /// de frescor, e `size_bytes`, que o servidor mediu.
  Future<void> markDelivered(String id, RoomMessage accepted) =>
      (db.update(db.localMessages)..where((t) => t.id.equals(id))).write(
        LocalMessagesCompanion(
          state: const Value(MessageState.delivered),
          createdAt: Value(accepted.createdAt),
          sizeBytes: Value(accepted.sizeBytes),
          authorId: Value(accepted.authorId),
          authorName: Value(accepted.authorName),
        ),
      );

  Future<void> setAudioPath(String id, String path) =>
      (db.update(db.localMessages)..where((t) => t.id.equals(id)))
          .write(LocalMessagesCompanion(audioPath: Value(path)));

  Future<void> markPlayed(String id) => _setState(id, MessageState.received);

  Future<LocalMessage?> byId(String id) =>
      (db.select(db.localMessages)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  Future<bool> exists(String id) async => (await byId(id)) != null;

  Future<int> countForRoom(int roomId) async =>
      (await forRoom(roomId)).length;

  Future<List<LocalMessage>> forRoom(int roomId) =>
      (db.select(db.localMessages)
            ..where((t) => t.roomId.equals(roomId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.recordedAt),
              (t) => OrderingTerm(expression: t.burstId),
              (t) => OrderingTerm(expression: t.segmentIndex),
            ]))
          .get();

  Stream<List<LocalMessage>> watchRoom(int roomId) =>
      (db.select(db.localMessages)
            ..where((t) => t.roomId.equals(roomId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.recordedAt, mode: OrderingMode.desc),
              (t) => OrderingTerm(expression: t.segmentIndex, mode: OrderingMode.desc),
            ]))
          .watch();

  /// O `since` do catch-up: o createdAt da última mensagem que vimos — um
  /// carimbo que o próprio servidor emitiu, nunca o relógio do celular.
  Future<DateTime?> lastSeenAt(int roomId) async {
    final query = db.select(db.localMessages)
      ..where((t) => t.roomId.equals(roomId) & t.createdAt.isNotNull())
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)])
      ..limit(1);

    return (await query.getSingleOrNull())?.createdAt;
  }
}
```

- [ ] **Passo 6: rodar e ver passar**

```bash
flutter test test/history/history_repository_test.dart
```

Esperado: `All tests passed!` (6 testes)

- [ ] **Passo 7: commit**

```bash
git add lib/history test/history
git commit -m "feat: histórico local em SQLite, permanente e 100% do dispositivo"
```

---

## Tarefa 10: WAV — embrulhar PCM sem comprimir

Grava PCM uma vez. A captura é PCM 16 kHz em stream; o WAV é só um cabeçalho de 44
bytes na frente. Gravar direto em formato comprimido obrigaria a Fase 3 a reescrever a
camada de áudio para voltar a ter PCM em stream.

**Arquivos:**
- Criar: `lib/audio/wav.dart`
- Testar: `test/audio/wav_test.dart`

- [ ] **Passo 1: escrever o teste que falha**

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/wav.dart';

void main() {
  test('o cabeçalho tem 44 bytes e declara PCM 16 bits mono a 16 kHz', () {
    final header = wavHeader(dataBytes: 160000);

    expect(header.length, 44);

    final view = ByteData.sublistView(header);
    expect(String.fromCharCodes(header.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(header.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(header.sublist(12, 16)), 'fmt ');
    expect(view.getUint32(16, Endian.little), 16, reason: 'tamanho do bloco fmt');
    expect(view.getUint16(20, Endian.little), 1, reason: '1 = PCM, sem compressão');
    expect(view.getUint16(22, Endian.little), 1, reason: 'mono');
    expect(view.getUint32(24, Endian.little), 16000);
    expect(view.getUint32(28, Endian.little), 32000, reason: 'bytes por segundo');
    expect(view.getUint16(32, Endian.little), 2, reason: 'alinhamento de bloco');
    expect(view.getUint16(34, Endian.little), 16, reason: 'bits por amostra');
    expect(String.fromCharCodes(header.sublist(36, 40)), 'data');
    expect(view.getUint32(40, Endian.little), 160000);
    expect(view.getUint32(4, Endian.little), 36 + 160000);
  });

  test('um segmento de 5 s dá ~160 KB, como a spec diz', () {
    expect(bytesPerMs, 32);

    final dataBytes = 5000 * bytesPerMs;
    final file = wrapPcmInWav(Uint8List(dataBytes));

    expect(file.length, 44 + 160000);
    expect(file.length / 1024, closeTo(156.3, 0.1));
  });

  test('o PCM sai do WAV byte a byte igual ao que entrou', () {
    final pcm = Uint8List.fromList(List.generate(1000, (i) => i % 256));

    final file = wrapPcmInWav(pcm);

    expect(file.sublist(44), pcm);
  });

  test('a duração sai da contagem de bytes, não de um relógio', () {
    expect(durationMsOfPcm(160000), 5000);
    expect(durationMsOfPcm(32000), 1000);
    expect(durationMsOfPcm(0), 0);
  });
}
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
flutter test test/audio/wav_test.dart
```

Esperado: FALHA com `Target of URI doesn't exist: 'package:flycomm/audio/wav.dart'`.

- [ ] **Passo 3: escrever a implementação mínima**

```dart
import 'dart:typed_data';

const sampleRate = 16000;
const channels = 1;
const bitsPerSample = 16;

/// PCM 16 bits mono a 16 kHz: 32 bytes por milissegundo. É deste número que
/// saem o teto do segmento e a duração de cada mensagem — a duração vem da
/// contagem de bytes, nunca de um cronômetro, que derrapa.
const bytesPerMs = sampleRate * channels * (bitsPerSample ~/ 8) ~/ 1000;

int durationMsOfPcm(int pcmBytes) => pcmBytes ~/ bytesPerMs;

/// Cabeçalho RIFF de 44 bytes. O servidor trata áudio como bytes opacos, então
/// trocar WAV por Opus ou AAC depois não toca no backend nem no schema — só
/// aqui e no campo `format`.
Uint8List wavHeader({required int dataBytes}) {
  const byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  const blockAlign = channels * bitsPerSample ~/ 8;

  final header = Uint8List(44);
  final view = ByteData.sublistView(header);

  void ascii(int offset, String text) {
    header.setRange(offset, offset + text.length, text.codeUnits);
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // 1 = PCM, sem compressão
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, byteRate, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, dataBytes, Endian.little);

  return header;
}

Uint8List wrapPcmInWav(Uint8List pcm) {
  final header = wavHeader(dataBytes: pcm.length);
  final file = Uint8List(header.length + pcm.length)
    ..setAll(0, header)
    ..setAll(header.length, pcm);

  return file;
}
```

- [ ] **Passo 4: rodar e ver passar**

```bash
flutter test test/audio/wav_test.dart
```

Esperado: `All tests passed!` (4 testes)

- [ ] **Passo 5: commit**

```bash
git add lib/audio/wav.dart test/audio/wav_test.dart
git commit -m "feat: embrulho WAV de PCM 16 bits 16 kHz"
```

---

## Tarefa 11: `PcmSegmenter` — o corte é no metadado, nunca no áudio

O teto de 5 s nasceu do rádio e na Fase 2, sozinha, parece burocracia. Vale mesmo
assim porque rajada e índice atravessam o schema do servidor, o SQLite local, a fila
de reprodução e o modo como a UI agrupa uma fala.

**Arquivos:**
- Criar: `lib/audio/segmenter.dart`
- Testar: `test/audio/segmenter_test.dart`

- [ ] **Passo 1: escrever o teste que falha**

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/segmenter.dart';
import 'package:flycomm/audio/wav.dart';

void main() {
  // 5 s de teto, o valor que GET /config devolve hoje.
  PcmSegmenter build() =>
      PcmSegmenter(segmentMax: const Duration(seconds: 5));

  /// Um pedaço de microfone de [ms] milissegundos, com bytes distinguíveis.
  Uint8List chunk(int ms, int seed) => Uint8List.fromList(
      List.generate(ms * bytesPerMs, (i) => (seed + i) % 256));

  test('uma fala de 12 s vira três mensagens', () {
    final segmenter = build();
    final closed = <Uint8List>[];

    // 120 pedaços de 100 ms = 12 s, como o microfone entrega.
    for (var i = 0; i < 120; i++) {
      closed.addAll(segmenter.add(chunk(100, i)));
    }
    final tail = segmenter.close();

    expect(closed, hasLength(2), reason: 'dois segmentos cheios de 5 s');
    expect(tail, isNotNull);
    expect(durationMsOfPcm(tail!.length), 2000, reason: 'e uma cauda de 2 s');
    expect(closed.length + 1, 3);
  });

  test('o corte é no metadado, nunca no áudio: nenhum byte se perde', () {
    final segmenter = build();
    final fed = <int>[];
    final out = <int>[];

    for (var i = 0; i < 120; i++) {
      final piece = chunk(100, i);
      fed.addAll(piece);
      for (final segment in segmenter.add(piece)) {
        out.addAll(segment);
      }
    }
    final tail = segmenter.close();
    if (tail != null) out.addAll(tail);

    expect(out, equals(fed),
        reason: 'ao fechar um segmento a captura não para, e o que sobrou do '
            'pedaço vai para o segmento seguinte');
  });

  test('cada segmento cheio tem exatamente o teto de duração', () {
    final segmenter = build();
    final closed = <Uint8List>[];

    for (var i = 0; i < 120; i++) {
      closed.addAll(segmenter.add(chunk(100, i)));
    }

    for (final segment in closed) {
      expect(durationMsOfPcm(segment.length), 5000);
    }
  });

  test('um pedaço grande fecha vários segmentos de uma vez', () {
    final segmenter = build();

    final closed = segmenter.add(chunk(16000, 0)); // 16 s de uma vez

    expect(closed, hasLength(3));
    expect(durationMsOfPcm(segmenter.close()!.length), 1000);
  });

  test('uma fala mais curta que o teto vira uma mensagem só', () {
    final segmenter = build();

    expect(segmenter.add(chunk(1200, 0)), isEmpty);

    final tail = segmenter.close();
    expect(durationMsOfPcm(tail!.length), 1200);
  });

  test('soltar o PTT sem ter falado não produz mensagem', () {
    expect(build().close(), isNull);
  });

  test('o teto vem do orçamento, não de uma constante', () {
    final segmenter = PcmSegmenter(segmentMax: const Duration(seconds: 2));

    final closed = segmenter.add(chunk(5000, 0));

    expect(closed, hasLength(2));
    expect(durationMsOfPcm(closed.first.length), 2000);
  });
}
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
flutter test test/audio/segmenter_test.dart
```

Esperado: FALHA com `Target of URI doesn't exist: 'package:flycomm/audio/segmenter.dart'`.

- [ ] **Passo 3: escrever a implementação mínima**

```dart
import 'dart:typed_data';

import 'wav.dart';

/// Fecha um segmento a cada [segmentMax] de áudio acumulado.
///
/// O corte é no metadado, nunca no áudio: [add] devolve os segmentos que este
/// pedaço fechou e guarda o resto para o próximo. Quem chama nunca para a
/// captura por causa de um fechamento.
///
/// O teto vem de `segment_max_ms` em GET /config, não de uma constante — e o
/// servidor recusa `duration_ms` acima dele, o que faz a regra de 5 s ser do
/// sistema e não só do app.
class PcmSegmenter {
  PcmSegmenter({required Duration segmentMax})
      : maxBytes = segmentMax.inMilliseconds * bytesPerMs;

  final int maxBytes;

  Uint8List _pending = Uint8List(0);

  List<Uint8List> add(Uint8List chunk) {
    final merged = Uint8List(_pending.length + chunk.length)
      ..setAll(0, _pending)
      ..setAll(_pending.length, chunk);

    final closed = <Uint8List>[];
    var offset = 0;

    while (merged.length - offset >= maxBytes) {
      closed.add(Uint8List.sublistView(merged, offset, offset + maxBytes));
      offset += maxBytes;
    }

    _pending = Uint8List.sublistView(merged, offset);

    return closed;
  }

  /// O último segmento, parcial, quando o piloto solta o PTT. Nulo se ele não
  /// chegou a falar nada.
  Uint8List? close() {
    if (_pending.isEmpty) return null;

    final tail = _pending;
    _pending = Uint8List(0);

    return tail;
  }
}
```

- [ ] **Passo 4: rodar e ver passar**

```bash
flutter test test/audio/segmenter_test.dart
```

Esperado: `All tests passed!` (7 testes)

- [ ] **Passo 5: commit**

```bash
git add lib/audio/segmenter.dart test/audio/segmenter_test.dart
git commit -m "feat: segmentação de 5 s que corta o metadado, nunca o áudio"
```

---

## Tarefa 12: `PlaybackQueue` — FIFO estrito, prazo e meio-duplex

O coração da Fase 2, e a parte que mais fácil se implementa errado. Três invariantes
numa classe só:

- **uma voz por vez**, nunca sobreposta, em ordem de chegada
- **item mais velho que `playback_deadline` sai da fila sem tocar** e vira "atrasada"
  no histórico — uma fila que só cresce é bug, não backlog
- **enquanto o PTT está acionado, nada toca** (meio-duplex)

Tudo em Dart puro, com relógio injetado: não precisa de emulador nem de alto-falante
para testar a regra.

**Arquivos:**
- Criar: `lib/audio/playback_queue.dart`
- Testar: `test/audio/playback_queue_test.dart`

- [ ] **Passo 1: escrever o teste que falha**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/playback_queue.dart';
import 'package:flycomm/room/budgets.dart';
import 'package:flycomm/room/server_clock.dart';

void main() {
  const budgets = Budgets(
    playbackDeadline: Duration(seconds: 30),
    radioRelayDeadline: Duration(seconds: 10),
    segmentMax: Duration(seconds: 5),
    catchupWindow: Duration(seconds: 60),
    blobTtl: Duration(minutes: 5),
  );

  late DateTime fakeNow;
  late ServerClock clock;
  late List<String> played;
  late List<String> dropped;
  late int concurrentPlays;
  late int maxConcurrentPlays;
  PlaybackQueue? open;

  /// Toca "instantaneamente" por padrão; os testes que precisam de duração
  /// passam um [advance] que empurra o relógio.
  PlaybackQueue build({Duration advance = Duration.zero}) {
    final queue = PlaybackQueue(
      clock: clock,
      budgets: budgets,
      play: (item) async {
        concurrentPlays++;
        maxConcurrentPlays =
            concurrentPlays > maxConcurrentPlays ? concurrentPlays : maxConcurrentPlays;
        await Future<void>.delayed(Duration.zero);
        fakeNow = fakeNow.add(advance);
        played.add(item.messageId);
        concurrentPlays--;
      },
    );
    queue.dropped.listen((item) => dropped.add(item.messageId));
    open = queue;
    return queue;
  }

  /// `drained` só diz que o laço de reprodução parou. O stream de descarte é
  /// broadcast e entrega em microtask, então observar um descarte exige ceder
  /// o laço de eventos uma vez. Sem isto, todo teste que espera um item em
  /// [dropped] falha — e o evento ainda aparece no teste SEGUINTE.
  Future<void> settle(PlaybackQueue queue) async {
    await queue.drained;
    await Future<void>.delayed(Duration.zero);
  }

  QueuedItem itemAgedBy(String id, Duration age) => QueuedItem(
        messageId: id,
        createdAt: clock.now().subtract(age),
      );

  setUp(() {
    fakeNow = DateTime.utc(2026, 9, 13, 16, 0, 0);
    clock = ServerClock(localNow: () => fakeNow)
      ..sync(serverTime: fakeNow, receivedAt: fakeNow);
    played = [];
    dropped = [];
    concurrentPlays = 0;
    maxConcurrentPlays = 0;
    open = null;
  });

  // Fecha o controlador: sem isto, um descarte entregue tarde cai na lista do
  // teste seguinte e o diagnóstico fica ilegível.
  tearDown(() async => open?.dispose());

  test('FIFO estrito: em ordem de chegada, nunca sobreposta', () async {
    final queue = build();

    queue.enqueue(itemAgedBy('a', const Duration(seconds: 1)));
    queue.enqueue(itemAgedBy('b', const Duration(seconds: 1)));
    queue.enqueue(itemAgedBy('c', const Duration(seconds: 1)));
    await settle(queue);

    expect(played, ['a', 'b', 'c']);
    expect(maxConcurrentPlays, 1, reason: 'uma voz por vez');
  });

  test('item além do prazo sai da fila SEM tocar', () async {
    final queue = build();

    queue.enqueue(itemAgedBy('fresca', const Duration(seconds: 5)));
    queue.enqueue(itemAgedBy('vencida', const Duration(seconds: 31)));
    await settle(queue);

    expect(played, ['fresca']);
    expect(dropped, ['vencida'],
        reason: 'vira "atrasada" no histórico, ouvível por toque, nunca '
            'automaticamente');
  });

  test('a cauda que vence esperando a vez também é descartada', () async {
    // Cada reprodução consome 20 s do relógio do servidor.
    final queue = build(advance: const Duration(seconds: 20));

    queue.enqueue(itemAgedBy('primeira', Duration.zero));
    queue.enqueue(itemAgedBy('segunda', Duration.zero));
    queue.enqueue(itemAgedBy('terceira', Duration.zero));
    await settle(queue);

    // primeira toca em t=0; segunda em t=20 (idade 20 s, ainda fresca);
    // terceira em t=40, idade 40 s > 30 s.
    expect(played, ['primeira', 'segunda']);
    expect(dropped, ['terceira'],
        reason: 'uma fila que só cresce é bug, não backlog');
  });

  test('meio-duplex: com o PTT acionado, nada toca', () async {
    final queue = build();

    queue.pttHeld = true;
    queue.enqueue(itemAgedBy('a', const Duration(seconds: 1)));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(played, isEmpty);
    expect(dropped, isEmpty, reason: 'a fila acumula, não descarta');

    queue.pttHeld = false;
    await settle(queue);

    expect(played, ['a']);
  });

  test('soltar o PTT depois do prazo descarta o que venceu esperando', () async {
    final queue = build();

    queue.pttHeld = true;
    queue.enqueue(itemAgedBy('a', const Duration(seconds: 1)));

    fakeNow = fakeNow.add(const Duration(seconds: 40));
    queue.pttHeld = false;
    await settle(queue);

    expect(played, isEmpty);
    expect(dropped, ['a']);
  });

  test('acionar o PTT no meio da fila para a fila depois do item atual', () async {
    final queue = build();

    queue.enqueue(itemAgedBy('a', Duration.zero));
    queue.enqueue(itemAgedBy('b', Duration.zero));
    queue.pttHeld = true;
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(played.length, lessThanOrEqualTo(1));
    expect(played, isNot(contains('b')));

    queue.pttHeld = false;
    await settle(queue);

    expect(played, contains('b'));
  });

  test('um item exatamente no prazo ainda toca', () async {
    final queue = build();

    queue.enqueue(itemAgedBy('limite', const Duration(seconds: 30)));
    await settle(queue);

    expect(played, ['limite']);
  });
}
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
flutter test test/audio/playback_queue_test.dart
```

Esperado: FALHA com `Target of URI doesn't exist: 'package:flycomm/audio/playback_queue.dart'`.

- [ ] **Passo 3: escrever a implementação mínima**

```dart
import 'dart:async';
import 'dart:collection';

import '../room/budgets.dart';
import '../room/server_clock.dart';

class QueuedItem {
  const QueuedItem({required this.messageId, required this.createdAt});

  final String messageId;

  /// A autoridade de frescor: o carimbo do servidor, nunca o do celular.
  final DateTime createdAt;
}

/// O app se comporta como um rádio: uma voz por vez, nunca sobreposta, em
/// ordem de chegada.
///
/// Três regras, todas da seção 2.1 da spec:
///
/// - o prazo é verificado no momento de desenfileirar, não de enfileirar: se a
///   fila tem oito mensagens, a cauda já venceu antes de chegar a vez
/// - item vencido sai SEM tocar e é anunciado em [dropped], para virar
///   "atrasada" no histórico — ouvível por toque, nunca automaticamente
/// - enquanto [pttHeld], nada toca: meio-duplex
class PlaybackQueue {
  PlaybackQueue({
    required this.clock,
    required this.budgets,
    required Future<void> Function(QueuedItem item) play,
  }) : _play = play;

  final ServerClock clock;
  final Budgets budgets;
  final Future<void> Function(QueuedItem item) _play;

  final Queue<QueuedItem> _items = Queue<QueuedItem>();
  final StreamController<QueuedItem> _dropped =
      StreamController<QueuedItem>.broadcast();

  Future<void>? _pumping;
  bool _pttHeld = false;

  /// Os itens que saíram da fila sem tocar por terem passado do prazo.
  Stream<QueuedItem> get dropped => _dropped.stream;

  int get length => _items.length;

  bool get pttHeld => _pttHeld;

  set pttHeld(bool value) {
    if (_pttHeld == value) return;
    _pttHeld = value;
    if (!value) _pump();
  }

  /// Completa quando não há mais nada a fazer agora. Existe para os testes e
  /// para o desligamento ordenado — a UI nunca espera por isto.
  Future<void> get drained => _pumping ?? Future<void>.value();

  void enqueue(QueuedItem item) {
    _items.add(item);
    _pump();
  }

  void _pump() {
    if (_pumping != null || _pttHeld) return;
    _pumping = _drain().whenComplete(() => _pumping = null);
  }

  Future<void> _drain() async {
    while (_items.isNotEmpty && !_pttHeld) {
      final item = _items.removeFirst();

      if (clock.ageOf(item.createdAt) > budgets.playbackDeadline) {
        _dropped.add(item);
        continue;
      }

      await _play(item);
    }
  }

  Future<void> dispose() async {
    _items.clear();
    await _dropped.close();
  }
}
```

- [ ] **Passo 4: rodar e ver passar**

```bash
flutter test test/audio/playback_queue_test.dart
```

Esperado: `All tests passed!` (7 testes)

- [ ] **Passo 5: rodar a suíte de unidade inteira**

```bash
flutter test test/room test/audio test/history
```

Esperado: `All tests passed!`

- [ ] **Passo 6: commit**

```bash
git add lib/audio/playback_queue.dart test/audio/playback_queue_test.dart
git commit -m "feat: fila FIFO com descarte por prazo e meio-duplex"
```

---

## Tarefa 13: `ReverbClient` — cliente Pusher em Dart puro

> **Por que não `pusher_channels_flutter`.** A spec §5.7 recomenda esse pacote como
> "compatível com Reverb". Ele não é, para um Reverb próprio: a camada Dart do
> `init()` nunca encaminha `host`, e o nativo do Android só aceita `cluster`, que
> resolve para `ws-<cluster>.pusher.com`. (O nativo do iOS até lê `args["host"]`, mas
> o Dart nunca o envia.) Verificado no fonte de `pusher_channels_flutter` 2.6.0.
>
> O protocolo que precisamos é pequeno — conectar, pegar o `socket_id`, trocá-lo por
> uma assinatura, assinar o canal, ler eventos — e escrevê-lo à mão remove o plugin
> nativo. **Ganho colateral grande: o cliente passa a rodar em `flutter test` no
> host, sem emulador.**

Duas armadilhas confirmadas na prática:

1. O canal no Laravel se chama `room.{id}`; **no fio o nome é `presence-room.{id}`**.
2. `/broadcasting/auth` está atrás de `auth:sanctum` — precisa do header
   `Authorization: Bearer <token>`, que o `ApiClient` já põe.

E uma terceira, que custa caro: **`channel_data` vai no subscribe exatamente como
veio**. É a string que o servidor assinou; reserializá-la invalida a assinatura.

**Arquivos:**
- Criar: `lib/room/reverb_client.dart`
- Testar: `test/integration/reverb_test.dart`

- [ ] **Passo 1: escrever `lib/room/reverb_client.dart`**

Copie o conteúdo de `lib/room/reverb_client.dart` como está no repositório — o
arquivo já foi escrito e verificado contra o Reverb real nesta sessão. Os pontos que
não podem mudar:

- `presenceChannelFor(int roomId) => 'presence-room.$roomId'`
- o `enum ReverbConnection { disconnected, connecting, connected }`
- as streams `messages`, `roomUpdates`, `presence`, `connectionState`
- responder `pusher:ping` com `pusher:pong` (sem isso o servidor derruba a conexão)
- `data` chega como **String JSON** na maioria dos eventos e como objeto em alguns:
  normalize com um único `_decode`
- **toda emissão passa por um guarda `isClosed`.** `dispose()` fecha os controladores
  e `disconnect()` emite; sem o guarda, chamar `dispose()` duas vezes estoura com
  `Bad state: Cannot add new events after calling close`. No teste isso aparece como
  uma falha num teste que não tem nada a ver — foi assim que apareceu aqui.
- reconexão com recuo exponencial **com teto de 8 s** — o catch-up só olha 60 s para
  trás, então demorar mais que isso para voltar começa a produzir buraco no histórico

- [ ] **Passo 2: escrever `test/integration/reverb_test.dart`**

Copie o arquivo como está no repositório. Note o par `setUpAll` + **`tearDownAll`**:
com `setUpAll` o cliente é criado uma vez por arquivo, então descartá-lo em `tearDown`
o mataria antes do segundo teste.

Ele usa o dispositivo semeado **`marina`**,
e não `rodrigo`, de propósito: cada `POST /auth/device` revoga o token anterior
daquele dispositivo, então dois arquivos de teste com o mesmo `identifier` se
derrubariam mutuamente.

O teste de `message.new` fica com `skip:` porque exige disparar a rajada à mão.

- [ ] **Passo 3: rodar**

```bash
flutter test -j 1 test/integration/reverb_test.dart --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Esperado: `+2 ~1: All tests passed!` — dois passam, o de `message.new` fica pulado.

Para exercitar o pulado: remova o `skip:`, rode o comando acima em segundo plano e
dispare a rajada dentro de 30 s:

```bash
cd ../flycomm-server && docker compose exec app php artisan flycomm:demo-burst 255 --from=511
```

- [ ] **Passo 4: commit**

```bash
git add lib/room/reverb_client.dart test/integration/reverb_test.dart
git commit -m "feat: cliente Pusher em Dart puro para o Reverb, com presenca e eventos"
```

---

## Tarefa 14: catch-up e detecção de buraco

O `catchup` não é backlog de quem esteve offline: é "o que foi publicado nos últimos
60 s que eu não vi". A janela é maior que o prazo de propósito — o excedente não toca,
mas preenche o histórico local do que passou enquanto o app estava desconectado.

**Arquivos:**
- Criar: `lib/room/catchup_repository.dart`
- Testar: `test/room/catchup_test.dart`
- Testar: `test/integration/catchup_test.dart`

- [ ] **Passo 1: escrever o teste de unidade que falha**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/catchup_repository.dart';

void main() {
  final windowStart = DateTime.utc(2026, 9, 13, 16, 0, 0);

  CatchupResult result() => CatchupResult(
        serverTime: windowStart.add(const Duration(seconds: 60)),
        windowStart: windowStart,
        messages: const [],
      );

  test('sem since — primeira entrada na sala — não é buraco', () {
    expect(result().hasGapSince(null), isFalse,
        reason: 'quem nunca viu nada não perdeu nada: o histórico é local e '
            'começa vazio, e o servidor nunca foi arquivo');
  });

  test('since dentro da janela: nada se perdeu', () {
    final since = windowStart.add(const Duration(seconds: 8));

    expect(result().hasGapSince(since), isFalse);
  });

  test('since mais antigo que a janela: houve buraco', () {
    final since = windowStart.subtract(const Duration(minutes: 5));

    expect(result().hasGapSince(since), isTrue,
        reason: 'o piso foi recuado até a janela; o que existiu entre o since '
            'e o window_start nunca vai chegar, e sem indício o buraco '
            'existiria sem ninguém saber');
  });

  test('since exatamente no window_start não é buraco', () {
    expect(result().hasGapSince(windowStart), isFalse);
  });

  test('lê o corpo real de GET /rooms/{id}/catchup', () {
    final parsed = CatchupResult.fromJson(const {
      'server_time': '2026-09-13T16:03:24.776469Z',
      'window_start': '2026-09-13T16:02:24.776469Z',
      'messages': [
        {
          'id': 'eb70d78f-0f90-4d83-9db2-0d2d28898a46',
          'room_id': 255,
          'burst_id': 'fbd46da5-f0a9-4754-940b-0768002c7e37',
          'index': 0,
          'user': {'id': 510, 'display_name': 'Marina'},
          'duration_ms': 1000,
          'origin': 'app',
          'format': 'wav/pcm16/16000',
          'size_bytes': 32044,
          'captured_at': '2026-09-13T16:03:18.000000Z',
          'created_at': '2026-09-13T16:03:18.000000Z',
          'expires_at': '2026-09-13T16:08:18.000000Z',
          'audio_url': 'http://servidor/messages/eb70d78f/audio',
        }
      ],
    });

    expect(parsed.messages, hasLength(1));
    expect(parsed.messages.single.authorName, 'Marina');
    expect(parsed.windowStart.isUtc, isTrue);
  });
}
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
flutter test test/room/catchup_test.dart
```

Esperado: FALHA com `Target of URI doesn't exist: 'package:flycomm/room/catchup_repository.dart'`.

- [ ] **Passo 3: escrever a implementação mínima**

```dart
import 'api_client.dart';
import 'models.dart';
import 'server_clock.dart';

class CatchupResult {
  const CatchupResult({
    required this.serverTime,
    required this.windowStart,
    required this.messages,
  });

  final DateTime serverTime;

  /// `agora - catchup_window`, sempre — e não o piso efetivo. É justamente por
  /// isso que dá para detectar buraco: se o campo devolvesse o piso efetivo,
  /// ele seria igual ao `since` sempre que o `since` fosse recente, e o buraco
  /// nunca apareceria.
  final DateTime windowStart;

  final List<RoomMessage> messages;

  /// Houve buraco no histórico: o app pediu desde um ponto que a janela não
  /// alcança, e o que existiu entre os dois não vai chegar nunca. Sem isso o
  /// buraco existiria sem nenhum indício.
  bool hasGapSince(DateTime? since) =>
      since != null && since.toUtc().isBefore(windowStart);

  factory CatchupResult.fromJson(Map<String, dynamic> json) => CatchupResult(
        serverTime: DateTime.parse(json['server_time'] as String).toUtc(),
        windowStart: DateTime.parse(json['window_start'] as String).toUtc(),
        messages: (json['messages'] as List<dynamic>)
            .map((e) => RoomMessage.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}

class CatchupRepository {
  CatchupRepository({required this.api, required this.clock});

  final ApiClient api;
  final ServerClock clock;

  /// [since] é o `created_at` da última mensagem vista — um carimbo que o
  /// próprio servidor emitiu, nunca o relógio do celular.
  Future<CatchupResult> fetch(int roomId, {DateTime? since}) async {
    final response = await api.send<Map<String, dynamic>>(
      'GET',
      '/rooms/$roomId/catchup',
      query: {
        if (since != null) 'since': since.toUtc().toIso8601String(),
      },
    );
    final receivedAt = DateTime.now().toUtc();

    final result = CatchupResult.fromJson(response.data!);
    clock.sync(serverTime: result.serverTime, receivedAt: receivedAt);

    return result;
  }
}
```

- [ ] **Passo 4: rodar e ver passar**

```bash
flutter test test/room/catchup_test.dart
```

Esperado: `All tests passed!` (5 testes)

- [ ] **Passo 5: escrever o teste de integração**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/catchup_repository.dart';
import 'package:flycomm/room/config_repository.dart';
import 'package:flycomm/room/device_identity.dart';
import 'package:flycomm/room/room_repository.dart';
import 'package:flycomm/room/server_clock.dart';

import 'env.dart';

void main() {
  late CatchupRepository catchup;
  late ServerClock clock;
  late int roomId;
  late Duration catchupWindow;

  setUp(() async {
    final api = ApiClient(baseUrl: httpBase);
    clock = ServerClock();

    final seeded = seededDevices['rodrigo']!;
    await AuthRepository(api: api).authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );

    catchupWindow =
        (await ConfigRepository(api: api, clock: clock).fetch()).budgets.catchupWindow;
    roomId = (await RoomRepository(api: api).join('FLY-TEST')).id;
    catchup = CatchupRepository(api: api, clock: clock);
  });

  test('sem since, a janela é a do servidor', () async {
    final result = await catchup.fetch(roomId);

    final width = result.serverTime.difference(result.windowStart);
    expect(width.inMilliseconds,
        closeTo(catchupWindow.inMilliseconds, 1000));
    expect(result.hasGapSince(null), isFalse);
  });

  test('since de dez minutos atrás é ignorado e vira buraco', () async {
    final since = clock.now().subtract(const Duration(minutes: 10));

    final result = await catchup.fetch(roomId, since: since);

    expect(result.hasGapSince(since), isTrue,
        reason: 'ausência longa não é coberta de propósito');
    expect(result.windowStart.isAfter(since), isTrue);
  });

  test('since recente não é buraco', () async {
    final since = clock.now().subtract(const Duration(seconds: 5));

    final result = await catchup.fetch(roomId, since: since);

    expect(result.hasGapSince(since), isFalse);
  });

  test('a rajada recém-publicada aparece no catch-up', () async {
    // Rode antes deste teste, em outro terminal:
    //   cd ../flycomm-server && docker compose exec app \
    //     php artisan flycomm:demo-burst 255 --from=510
    final result = await catchup.fetch(roomId);

    if (result.messages.isEmpty) {
      markTestSkipped('nenhuma rajada fresca; dispare flycomm:demo-burst');
      return;
    }

    final burst = result.messages.first.burstId;
    final segments = result.messages.where((m) => m.burstId == burst).toList();

    expect(segments.map((m) => m.index), orderedEquals(
        List.generate(segments.length, (i) => i)),
        reason: 'os segmentos de uma rajada chegam em ordem de índice');
  });
}
```

- [ ] **Passo 6: rodar**

```bash
cd ../flycomm-server && docker compose exec app php artisan flycomm:demo-burst 255 --from=510 && cd ../flycomm-app
```

```bash
flutter test -j 1 test/integration/catchup_test.dart --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Esperado: `All tests passed!` (4 testes)

- [ ] **Passo 7: commit**

```bash
git add lib/room/catchup_repository.dart test/room/catchup_test.dart test/integration/catchup_test.dart
git commit -m "feat: catch-up com detecção de buraco no histórico"
```

---

## Tarefa 15: `MessageApi` e `AudioStore` — subir e baixar áudio

**Arquivos:**
- Criar: `lib/room/message_api.dart`
- Criar: `lib/history/audio_store.dart`
- Testar: `test/integration/messages_test.dart`

- [ ] **Passo 1: escrever `lib/history/audio_store.dart`**

```dart
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
```

- [ ] **Passo 2: escrever `lib/room/message_api.dart`**

```dart
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_client.dart';
import 'models.dart';

/// O que o app grava e ainda não subiu.
class OutgoingSegment {
  const OutgoingSegment({
    required this.id,
    required this.roomId,
    required this.burstId,
    required this.index,
    required this.durationMs,
    required this.capturedAt,
    required this.wavBytes,
  });

  /// uuid gerado pelo APP. É o que torna o upload idempotente: a retentativa
  /// insiste durante toda a janela de validade, e sem um id estável cada
  /// tentativa em rede ruim criaria uma mensagem duplicada na sala.
  final String id;

  final int roomId;
  final String burstId;
  final int index;
  final int durationMs;
  final DateTime capturedAt;
  final Uint8List wavBytes;
}

class MessageApi {
  MessageApi({required this.api});

  final ApiClient api;

  /// O valor de `format` que a spec manda enviar na Fase 2.
  ///
  /// O servidor grava e devolve `wav/pcm16/16000` na sua própria rajada de
  /// demonstração — divergência registrada na seção 0.1 deste plano, a ser
  /// resolvida com um commit no repo `flycomm`. O app NÃO condiciona
  /// reprodução a este valor: ele decodifica WAV sempre, então as duas
  /// grafias tocam.
  static const format = 'wav-pcm16-16k';

  /// 201 quando a mensagem é nova, 200 quando o id já existia — e nesse caso
  /// o servidor devolve a mensagem gravada sem republicar o evento.
  Future<RoomMessage> publish(OutgoingSegment segment) async {
    final form = FormData.fromMap({
      'id': segment.id,
      'burst_id': segment.burstId,
      'index': segment.index,
      'duration_ms': segment.durationMs,
      'origin': 'app',
      'format': format,
      'captured_at': segment.capturedAt.toUtc().toIso8601String(),
      'audio': MultipartFile.fromBytes(
        segment.wavBytes,
        filename: '${segment.id}.wav',
      ),
    });

    final response = await api.send<Map<String, dynamic>>(
      'POST',
      '/rooms/${segment.roomId}/messages',
      data: form,
    );

    return RoomMessage.fromJson(response.data!);
  }

  /// O endpoint responde `application/octet-stream` com `Accept-Ranges: bytes`
  /// — retomável, para sobreviver a sinal ruim.
  Future<Uint8List> download(String audioUrl) async {
    try {
      final response = await api.raw.get<List<int>>(
        audioUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data!);
    } on DioException catch (e) {
      throw ApiException(
        statusCode: e.response?.statusCode,
        message: e.message ?? 'falha ao baixar o áudio',
      );
    }
  }
}
```

- [ ] **Passo 3: escrever o teste de integração**

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/audio/wav.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/auth_repository.dart';
import 'package:flycomm/room/config_repository.dart';
import 'package:flycomm/room/device_identity.dart';
import 'package:flycomm/room/message_api.dart';
import 'package:flycomm/room/room_repository.dart';
import 'package:flycomm/room/server_clock.dart';
import 'package:uuid/uuid.dart';

import 'env.dart';

void main() {
  const uuid = Uuid();

  late MessageApi messages;
  late int roomId;
  late Duration segmentMax;

  Uint8List tone(int ms) => wrapPcmInWav(
      Uint8List.fromList(List.generate(ms * bytesPerMs, (i) => i % 256)));

  OutgoingSegment segment({
    required String id,
    required String burstId,
    int index = 0,
    int durationMs = 1000,
  }) =>
      OutgoingSegment(
        id: id,
        roomId: roomId,
        burstId: burstId,
        index: index,
        durationMs: durationMs,
        capturedAt: DateTime.now().toUtc(),
        wavBytes: tone(durationMs),
      );

  setUp(() async {
    final api = ApiClient(baseUrl: httpBase);
    final clock = ServerClock();

    final seeded = seededDevices['rodrigo']!;
    await AuthRepository(api: api).authenticate(
      DeviceCredentials(identifier: seeded.identifier, secret: seeded.secret),
      displayName: seeded.name,
    );

    segmentMax =
        (await ConfigRepository(api: api, clock: clock).fetch()).budgets.segmentMax;
    roomId = (await RoomRepository(api: api).join('FLY-TEST')).id;
    messages = MessageApi(api: api);
  });

  test('sobe um segmento e recebe o metadado completo de volta', () async {
    final id = uuid.v4();

    final published = await messages.publish(
      segment(id: id, burstId: uuid.v4()),
    );

    expect(published.id, id, reason: 'o id é do app, não do servidor');
    expect(published.origin, 'app');
    expect(published.authorName, isNotNull);
    expect(published.createdAt.isUtc, isTrue);
    expect(published.expiresAt.isAfter(published.createdAt), isTrue);
    expect(published.audioUrl, contains('/messages/$id/audio'));
  });

  test('reenviar o mesmo id é idempotente: mesma mensagem, sem duplicar', () async {
    final id = uuid.v4();
    final burstId = uuid.v4();

    final first = await messages.publish(segment(id: id, burstId: burstId));
    final second = await messages.publish(segment(id: id, burstId: burstId));

    expect(second.id, first.id);
    expect(second.createdAt, first.createdAt,
        reason: 'a retentativa devolve a gravada, não cria outra');
  });

  test('o áudio volta byte a byte igual pelo audio_url', () async {
    final id = uuid.v4();
    final sent = tone(1000);

    final published = await messages.publish(
      OutgoingSegment(
        id: id,
        roomId: roomId,
        burstId: uuid.v4(),
        index: 0,
        durationMs: 1000,
        capturedAt: DateTime.now().toUtc(),
        wavBytes: sent,
      ),
    );

    final received = await messages.download(published.audioUrl);

    expect(received, equals(sent),
        reason: 'o servidor trata áudio como bytes opacos');
    expect(published.sizeBytes, sent.length);
  });

  test('duração acima de segment_max é recusada com 422', () async {
    await expectLater(
      messages.publish(segment(
        id: uuid.v4(),
        burstId: uuid.v4(),
        durationMs: segmentMax.inMilliseconds + 1,
      )),
      throwsA(isA<ApiException>().having((e) => e.isValidation, 'isValidation', isTrue)),
      reason: 'a regra de 5 s é do sistema, não só do app: um cliente que '
          'ignore a segmentação é recusado pelo servidor',
    );
  });

  test('uma rajada de três segmentos guarda burst_id e índice', () async {
    final burstId = uuid.v4();

    for (var index = 0; index < 3; index++) {
      final published = await messages.publish(
        segment(id: uuid.v4(), burstId: burstId, index: index),
      );

      expect(published.burstId, burstId);
      expect(published.index, index);
    }
  });
}
```

- [ ] **Passo 4: rodar**

```bash
flutter test -j 1 test/integration/messages_test.dart --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Esperado: `All tests passed!` (5 testes)

- [ ] **Passo 5: commit**

```bash
git add lib/room/message_api.dart lib/history/audio_store.dart test/integration/messages_test.dart
git commit -m "feat: upload idempotente e download de áudio com o metadado único"
```

---

## Tarefa 16: `MessageUploader` — insiste na janela, depois desiste

**Não existe fila de saída persistente.** Guardar uma mensagem para subir "quando der"
só faria sentido se alguém fosse ouvi-la, e não vai. O upload tenta durante a janela de
validade e desiste; a mensagem fica no histórico local como **não entregue**, e o
piloto precisa ver isso — é a informação de que ninguém o ouviu.

A janela usada aqui é `playback_deadline_ms` a partir de `captured_at`; ver a seção
0.2 deste plano para o porquê e para como trocar.

**Arquivos:**
- Criar: `lib/room/message_uploader.dart`
- Testar: `test/room/message_uploader_test.dart`

- [ ] **Passo 1: escrever o teste que falha**

```dart
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/history/database.dart';
import 'package:flycomm/history/history_repository.dart';
import 'package:flycomm/room/api_client.dart';
import 'package:flycomm/room/budgets.dart';
import 'package:flycomm/room/message_api.dart';
import 'package:flycomm/room/message_uploader.dart';
import 'package:flycomm/room/models.dart';
import 'package:flycomm/room/server_clock.dart';

void main() {
  const budgets = Budgets(
    playbackDeadline: Duration(seconds: 30),
    radioRelayDeadline: Duration(seconds: 10),
    segmentMax: Duration(seconds: 5),
    catchupWindow: Duration(seconds: 60),
    blobTtl: Duration(minutes: 5),
  );

  late DateTime fakeNow;
  late ServerClock clock;
  late HistoryDatabase db;
  late HistoryRepository history;

  setUp(() async {
    fakeNow = DateTime.utc(2026, 9, 13, 16, 0, 0);
    clock = ServerClock(localNow: () => fakeNow)
      ..sync(serverTime: fakeNow, receivedAt: fakeNow);
    db = HistoryDatabase(NativeDatabase.memory());
    history = HistoryRepository(db);
  });

  tearDown(() => db.close());

  OutgoingSegment segment({DateTime? capturedAt}) => OutgoingSegment(
        id: 'msg-1',
        roomId: 255,
        burstId: 'burst-1',
        index: 0,
        durationMs: 5000,
        capturedAt: capturedAt ?? fakeNow,
        wavBytes: Uint8List(44),
      );

  RoomMessage accepted() => RoomMessage(
        id: 'msg-1',
        roomId: 255,
        burstId: 'burst-1',
        index: 0,
        authorId: 509,
        authorName: 'Rodrigo',
        durationMs: 5000,
        origin: 'app',
        format: 'wav-pcm16-16k',
        sizeBytes: 160044,
        capturedAt: fakeNow,
        createdAt: fakeNow.add(const Duration(milliseconds: 200)),
        expiresAt: fakeNow.add(const Duration(minutes: 5)),
        audioUrl: 'http://servidor/messages/msg-1/audio',
      );

  Future<void> recordIt(OutgoingSegment s) => history.recordOutgoing(
        id: s.id,
        roomId: s.roomId,
        burstId: s.burstId,
        index: s.index,
        durationMs: s.durationMs,
        format: MessageApi.format,
        capturedAt: s.capturedAt,
        audioPath: '/tmp/${s.id}.wav',
      );

  MessageUploader build(Future<RoomMessage> Function(OutgoingSegment) publish) =>
      MessageUploader(
        clock: clock,
        budgets: budgets,
        history: history,
        publish: publish,
        // Em vez de dormir de verdade, o backoff empurra o relógio falso.
        wait: (d) async => fakeNow = fakeNow.add(d),
      );

  test('sucesso de primeira: gravada → enviando → entregue', () async {
    final s = segment();
    await recordIt(s);

    await build((_) async => accepted()).upload(s);

    final row = (await history.byId('msg-1'))!;
    expect(row.state, MessageState.delivered);
    expect(row.createdAt, isNotNull);
  });

  test('insiste enquanto a janela de validade não fecha', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      if (attempts < 3) {
        throw ApiException(statusCode: null, message: 'sem rede');
      }
      return accepted();
    }).upload(s);

    expect(attempts, 3);
    expect((await history.byId('msg-1'))!.state, MessageState.delivered);
  });

  test('passada a janela, desiste e marca NÃO ENTREGUE', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      throw ApiException(statusCode: null, message: 'sem rede');
    }).upload(s);

    expect(attempts, greaterThan(1));
    expect(clock.now().difference(s.capturedAt),
        greaterThanOrEqualTo(budgets.playbackDeadline));

    final row = (await history.byId('msg-1'))!;
    expect(row.state, MessageState.undelivered,
        reason: 'a informação de que o piloto precisa é que ninguém o ouviu');
    expect(row.createdAt, isNull);
    expect(row.audioPath, isNotNull,
        reason: 'o histórico é permanente mesmo quando a mensagem não saiu');
  });

  test('422 não é retentado: o servidor recusou o conteúdo, não a rede', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      throw ApiException(statusCode: 422, message: 'duration_ms inválido');
    }).upload(s);

    expect(attempts, 1);
    expect((await history.byId('msg-1'))!.state, MessageState.undelivered);
  });

  test('409 não é retentado: o id pertence a outra sala', () async {
    final s = segment();
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      throw ApiException(statusCode: 409, message: 'id de outra sala');
    }).upload(s);

    expect(attempts, 1);
    expect((await history.byId('msg-1'))!.state, MessageState.undelivered);
  });

  test('segmento que já nasceu vencido não tenta nem uma vez', () async {
    final s = segment(capturedAt: fakeNow.subtract(const Duration(minutes: 2)));
    await recordIt(s);
    var attempts = 0;

    await build((_) async {
      attempts++;
      return accepted();
    }).upload(s);

    expect(attempts, 0, reason: 'gravado sem rede há dois minutos: ninguém '
        'tocaria isso, e insistir gasta bateria à toa');
    expect((await history.byId('msg-1'))!.state, MessageState.undelivered);
  });
}
```

- [ ] **Passo 2: rodar e ver falhar**

```bash
flutter test test/room/message_uploader_test.dart
```

Esperado: FALHA com `Target of URI doesn't exist: 'package:flycomm/room/message_uploader.dart'`.

- [ ] **Passo 3: escrever a implementação mínima**

```dart
import 'dart:async';

import '../history/history_repository.dart';
import 'api_client.dart';
import 'budgets.dart';
import 'message_api.dart';
import 'models.dart';
import 'server_clock.dart';

/// Sobe um segmento insistindo durante a janela de validade e desistindo
/// depois. Vive em memória e morre com o processo, de propósito: não existe
/// fila de saída persistente, porque guardar uma mensagem para subir "quando
/// der" só faria sentido se alguém fosse ouvi-la.
class MessageUploader {
  MessageUploader({
    required this.clock,
    required this.budgets,
    required this.history,
    required Future<RoomMessage> Function(OutgoingSegment) publish,
    Future<void> Function(Duration)? wait,
  })  : _publish = publish,
        _wait = wait ?? Future<void>.delayed;

  final ServerClock clock;
  final Budgets budgets;
  final HistoryRepository history;
  final Future<RoomMessage> Function(OutgoingSegment) _publish;
  final Future<void> Function(Duration) _wait;

  /// A janela de validade. Ver a seção 0.2 do plano: passado o prazo de
  /// reprodução ninguém tocaria o áudio, então insistir é gastar bateria e
  /// rádio por nada. Trocar por `catchupWindow` é mudar esta linha.
  Duration get validityWindow => budgets.playbackDeadline;

  Future<void> upload(OutgoingSegment segment) async {
    final deadline = segment.capturedAt.toUtc().add(validityWindow);
    var attempt = 0;

    while (clock.now().isBefore(deadline)) {
      if (attempt == 0) await history.markSending(segment.id);
      attempt++;

      try {
        final accepted = await _publish(segment);
        await history.markDelivered(segment.id, accepted);
        return;
      } on ApiException catch (e) {
        // 422 e 409 são recusa de conteúdo, não de rede: retentar reproduz o
        // mesmo erro até a janela fechar.
        if (e.isValidation || e.isConflict) break;
        await _wait(_backoff(attempt));
      } catch (_) {
        await _wait(_backoff(attempt));
      }
    }

    await history.markUndelivered(segment.id);
  }

  /// Cresce até 4 s e para de crescer: com uma janela de 30 s, esperar mais
  /// que isso desperdiça tentativas que ainda caberiam.
  Duration _backoff(int attempt) => Duration(
        milliseconds: (500 * (1 << (attempt - 1))).clamp(500, 4000),
      );
}
```

- [ ] **Passo 4: rodar e ver passar**

```bash
flutter test test/room/message_uploader_test.dart
```

Esperado: `All tests passed!` (6 testes)

- [ ] **Passo 5: commit**

```bash
git add lib/room/message_uploader.dart test/room/message_uploader_test.dart
git commit -m "feat: upload que insiste na janela e marca não entregue ao desistir"
```

---

## Tarefa 17: `PttRecorder` — PCM 16 kHz em stream

Segura o PTT → PCM 16 kHz em stream → a cada 5 s fecha um segmento e sobe, sem parar
de capturar. Solta o PTT → fecha o último segmento.

**Arquivos:**
- Criar: `lib/audio/recorder.dart`

Não há teste automatizado desta classe: ela é uma casca sobre o plugin `record`, e o
que ela tem de lógica própria — o corte — já está testado na Tarefa 11. A verificação
é a Tarefa 21.

- [ ] **Passo 1: escrever `lib/audio/recorder.dart`**

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'segmenter.dart';
import 'wav.dart';

/// Um segmento fechado, pronto para subir.
class CapturedSegment {
  const CapturedSegment({
    required this.id,
    required this.burstId,
    required this.index,
    required this.durationMs,
    required this.capturedAt,
    required this.wavBytes,
  });

  final String id;
  final String burstId;
  final int index;
  final int durationMs;
  final DateTime capturedAt;
  final Uint8List wavBytes;
}

/// Captura PCM 16 bits a 16 kHz em stream e a corta em segmentos.
///
/// Grava PCM uma vez: a Fase 3 deriva ADPCM 8 kHz deste mesmo PCM, e gravar
/// direto em formato comprimido obrigaria a reescrever a camada de áudio.
class PttRecorder {
  PttRecorder({
    required this.segmentMax,
    required DateTime Function() serverNow,
    AudioRecorder? recorder,
  })  : _serverNow = serverNow,
        _recorder = recorder ?? AudioRecorder();

  final Duration segmentMax;
  final DateTime Function() _serverNow;
  final AudioRecorder _recorder;
  final _uuid = const Uuid();

  final _segments = StreamController<CapturedSegment>.broadcast();

  /// Os segmentos fechados, na ordem. Quem escuta sobe cada um assim que
  /// chega — a fala de 12 s já está subindo enquanto o piloto ainda fala.
  Stream<CapturedSegment> get segments => _segments.stream;

  StreamSubscription<Uint8List>? _subscription;
  PcmSegmenter? _segmenter;
  String? _burstId;
  int _index = 0;
  bool _recording = false;

  bool get isRecording => _recording;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// O piloto segurou o PTT.
  Future<void> start() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('sem permissão de microfone');
    }

    _burstId = _uuid.v4();
    _index = 0;
    _segmenter = PcmSegmenter(segmentMax: segmentMax);
    _recording = true;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        // Eco e ruído ficam ligados: o piloto está num ambiente barulhento e
        // meio-duplex já garante que nada toca enquanto ele fala.
      ),
    );

    _subscription = stream.listen(
      (chunk) {
        for (final pcm in _segmenter!.add(chunk)) {
          _emit(pcm);
        }
      },
      onError: (Object error, StackTrace stack) =>
          _segments.addError(error, stack),
    );
  }

  /// O piloto soltou o PTT: fecha o último segmento, que é parcial.
  Future<void> stop() async {
    if (!_recording) return;
    _recording = false;

    await _subscription?.cancel();
    _subscription = null;
    await _recorder.stop();

    final tail = _segmenter?.close();
    if (tail != null && tail.isNotEmpty) _emit(tail);

    _segmenter = null;
    _burstId = null;
  }

  void _emit(Uint8List pcm) {
    _segments.add(CapturedSegment(
      id: _uuid.v4(),
      burstId: _burstId!,
      index: _index++,
      durationMs: durationMsOfPcm(pcm.length),
      // O carimbo do cliente, só para o histórico — a autoridade de frescor é
      // o created_at que o servidor emite.
      capturedAt: _serverNow(),
      wavBytes: wrapPcmInWav(pcm),
    ));
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
    await _segments.close();
  }
}
```

- [ ] **Passo 2: verificar que compila**

```bash
flutter analyze
```

Esperado: `No issues found!`

- [ ] **Passo 3: commit**

```bash
git add lib/audio/recorder.dart
git commit -m "feat: captura PCM 16 kHz em stream cortada em segmentos"
```

---

## Tarefa 18: `SegmentPlayer` — uma voz por vez

**Arquivos:**
- Criar: `lib/audio/player.dart`

- [ ] **Passo 1: escrever `lib/audio/player.dart`**

```dart
import 'package:just_audio/just_audio.dart';

/// Toca um arquivo por vez, do começo ao fim.
///
/// Um player só, reusado: dois players seriam duas vozes ao mesmo tempo, que é
/// exatamente o que a fila FIFO existe para impedir.
class SegmentPlayer {
  final _player = AudioPlayer();

  /// Completa quando o segmento termina. A PlaybackQueue faz `await` nisto, e
  /// é esse await que mantém a fila serial.
  Future<void> play(String filePath) async {
    await _player.setFilePath(filePath);
    await _player.play();
    await _player.stop();
  }

  Future<void> interrupt() => _player.stop();

  Future<void> dispose() => _player.dispose();
}
```

- [ ] **Passo 2: verificar**

```bash
flutter analyze
```

Esperado: `No issues found!`

- [ ] **Passo 3: commit**

```bash
git add lib/audio/player.dart
git commit -m "feat: reprodução serial de um segmento por vez"
```

---

## Tarefa 19: `RoomSession` — a amarração

A peça que faz as outras conversarem. Sem lógica nova: só a ordem em que as regras já
escritas se aplicam.

**Arquivos:**
- Criar: `lib/room/room_session.dart`

- [ ] **Passo 1: escrever `lib/room/room_session.dart`**

```dart
import 'dart:async';

import '../audio/playback_queue.dart';
import '../audio/player.dart';
import '../audio/recorder.dart';
import '../history/audio_store.dart';
import '../history/database.dart';
import '../history/history_repository.dart';
import 'budgets.dart';
import 'catchup_repository.dart';
import 'message_api.dart';
import 'message_uploader.dart';
import 'models.dart';
import 'reverb_client.dart';
import 'server_clock.dart';

/// Uma sessão de sala aberta: o WebSocket, a fila, o gravador e o histórico
/// amarrados. Uma instância por sala aberta; `dispose` ao sair.
class RoomSession {
  RoomSession({
    required this.room,
    required this.budgets,
    required this.clock,
    required this.reverb,
    required this.catchup,
    required this.messageApi,
    required this.history,
    required this.audioStore,
    required this.recorder,
    required this.player,
  }) {
    _queue = PlaybackQueue(
      clock: clock,
      budgets: budgets,
      play: _playFromStore,
    );

    _uploader = MessageUploader(
      clock: clock,
      budgets: budgets,
      history: history,
      publish: messageApi.publish,
    );

    // Item que passou do prazo sai da fila sem tocar e vira "atrasada" no
    // histórico — ouvível por toque, nunca automaticamente.
    _subscriptions.add(_queue.dropped.listen((item) async {
      await history.markLate(item.messageId);
    }));

    _subscriptions.add(reverb.messages.listen(ingest));

    _subscriptions.add(reverb.roomUpdates.listen((updated) {
      _room = updated;
      _roomChanges.add(updated);
    }));

    _subscriptions.add(recorder.segments.listen(_publishSegment));

    _room = room;
  }

  final Room room;
  final Budgets budgets;
  final ServerClock clock;
  final ReverbClient reverb;
  final CatchupRepository catchup;
  final MessageApi messageApi;
  final HistoryRepository history;
  final AudioStore audioStore;
  final PttRecorder recorder;
  final SegmentPlayer player;

  late final PlaybackQueue _queue;
  late final MessageUploader _uploader;

  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _roomChanges = StreamController<Room>.broadcast();
  final _gaps = StreamController<DateTime>.broadcast();

  late Room _room;

  Room get current => _room;
  Stream<Room> get roomChanges => _roomChanges.stream;

  /// Emite quando o catch-up descobriu um buraco no histórico.
  Stream<DateTime> get gaps => _gaps.stream;

  Stream<List<LocalMessage>> get messages => history.watchRoom(room.id);
  Stream<RoomPresence> get presence => reverb.presence;
  Stream<ReverbConnection> get connectionState => reverb.connectionState;

  Future<void> open() async {
    // Cada (re)assinatura roda o catch-up de novo. É isto que cobre o caso para
    // o qual a janela de 60 s foi desenhada: o WebSocket cai e volta oito
    // segundos depois, e o que passou nesse intervalo precisa entrar.
    _subscriptions.add(reverb.connectionState.listen((state) {
      if (state == ReverbConnection.connected) syncCatchup();
    }));

    await reverb.connect(room);
    await syncCatchup();
  }

  /// Chamado na entrada e a cada reconexão do WebSocket.
  Future<void> syncCatchup() async {
    final since = await history.lastSeenAt(room.id);
    final result = await catchup.fetch(room.id, since: since);

    if (result.hasGapSince(since)) _gaps.add(result.windowStart);

    for (final message in result.messages) {
      await ingest(message);
    }
  }

  /// O caminho único de entrada: o evento, a resposta do upload e o catch-up
  /// chegam aqui, porque são a mesma mensagem.
  Future<void> ingest(RoomMessage message) async {
    if (await history.exists(message.id)) return;

    // O excedente da janela de catch-up não toca, mas preenche o histórico:
    // sem isso haveria um buraco sem nenhum indício de que algo aconteceu ali.
    final tooOld = clock.ageOf(message.createdAt) > budgets.playbackDeadline;

    await history.recordIncoming(
      message,
      tooOld ? MessageState.late : MessageState.received,
    );

    try {
      final bytes = await messageApi.download(message.audioUrl);
      await audioStore.write(message.id, bytes);
      await history.setAudioPath(message.id, audioStore.pathFor(message.id));
    } catch (_) {
      // O blob expirou ou a rede caiu. A linha fica no histórico sem áudio:
      // o piloto vê que algo foi dito e que não dá para ouvir.
      await history.markLate(message.id);
      return;
    }

    if (!tooOld) {
      _queue.enqueue(
        QueuedItem(messageId: message.id, createdAt: message.createdAt),
      );
    }
  }

  Future<void> _playFromStore(QueuedItem item) async {
    if (!audioStore.has(item.messageId)) return;
    await player.play(audioStore.pathFor(item.messageId));
    await history.markPlayed(item.messageId);
  }

  /// Reprodução por toque, do histórico. Entra na mesma fila e respeita o
  /// meio-duplex, mas ignora o prazo: o piloto pediu para ouvir.
  Future<void> playFromHistory(String messageId) async {
    if (!audioStore.has(messageId)) return;
    await player.play(audioStore.pathFor(messageId));
  }

  /// Meio-duplex: enquanto o PTT está acionado, nada toca.
  Future<void> pressPtt() async {
    _queue.pttHeld = true;
    await player.interrupt();
    await recorder.start();
  }

  Future<void> releasePtt() async {
    await recorder.stop();
    _queue.pttHeld = false;
  }

  Future<void> _publishSegment(CapturedSegment segment) async {
    final path = await audioStore.write(segment.id, segment.wavBytes);

    await history.recordOutgoing(
      id: segment.id,
      roomId: room.id,
      burstId: segment.burstId,
      index: segment.index,
      durationMs: segment.durationMs,
      format: MessageApi.format,
      capturedAt: segment.capturedAt,
      audioPath: path,
    );

    await _uploader.upload(OutgoingSegment(
      id: segment.id,
      roomId: room.id,
      burstId: segment.burstId,
      index: segment.index,
      durationMs: segment.durationMs,
      capturedAt: segment.capturedAt,
      wavBytes: segment.wavBytes,
    ));
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _queue.dispose();
    await reverb.dispose();
    await recorder.dispose();
    await player.dispose();
    await _roomChanges.close();
    await _gaps.close();
  }
}
```

- [ ] **Passo 2: acrescentar `markLate` ao `HistoryRepository`**

Em `lib/history/history_repository.dart`, logo depois de `markPlayed`:

```dart
  /// Saiu da fila sem tocar, ou o áudio não pôde ser baixado. Fica ouvível por
  /// toque, nunca automaticamente.
  Future<void> markLate(String id) => _setState(id, MessageState.late);
```

- [ ] **Passo 3: verificar**

```bash
flutter analyze && flutter test test/room test/audio test/history
```

Esperado: `No issues found!` e `All tests passed!`

- [ ] **Passo 4: commit**

```bash
git add lib/room/room_session.dart lib/history/history_repository.dart
git commit -m "feat: RoomSession amarrando evento, fila, upload e histórico"
```

---

## Tarefa 20: arranque e tela de salas

O desenho de UI era questão em aberto na spec (seção 10). O que ela precisa mostrar já
está decidido pelas invariantes: **quem está na sala**, **em que frequência**, **o que
foi dito** e, sobretudo, **o que não foi entregue**.

Duas telas. Sem navegação nomeada, sem roteador: não há terceira tela para justificar.

**Arquivos:**
- Criar: `lib/ui/app_scope.dart`
- Criar: `lib/ui/rooms_screen.dart`
- Modificar: `lib/main.dart`
- Criar: `lib/app.dart`

- [ ] **Passo 1: escrever `lib/ui/app_scope.dart`**

```dart
import 'package:flutter/widgets.dart';

import '../history/audio_store.dart';
import '../history/database.dart';
import '../history/history_repository.dart';
import '../room/api_client.dart';
import '../room/auth_repository.dart';
import '../room/budgets.dart';
import '../room/catchup_repository.dart';
import '../room/message_api.dart';
import '../room/room_repository.dart';
import '../room/server_clock.dart';

/// Tudo que vive enquanto o app vive. Um InheritedWidget basta: não há estado
/// global mutável aqui, só as dependências já construídas.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.api,
    required this.clock,
    required this.config,
    required this.auth,
    required this.rooms,
    required this.catchup,
    required this.messageApi,
    required this.history,
    required this.audioStore,
    required this.userId,
    required super.child,
  });

  final ApiClient api;
  final ServerClock clock;
  final ServerConfig config;
  final AuthRepository auth;
  final RoomRepository rooms;
  final CatchupRepository catchup;
  final MessageApi messageApi;
  final HistoryRepository history;
  final AudioStore audioStore;
  final int userId;

  Budgets get budgets => config.budgets;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope não encontrado acima deste widget');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}

/// Fecha o banco quando o app morre. Separado do AppScope porque
/// InheritedWidget não tem dispose.
class DatabaseHolder extends StatefulWidget {
  const DatabaseHolder({super.key, required this.db, required this.child});

  final HistoryDatabase db;
  final Widget child;

  @override
  State<DatabaseHolder> createState() => _DatabaseHolderState();
}

class _DatabaseHolderState extends State<DatabaseHolder> {
  @override
  void dispose() {
    widget.db.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
```

- [ ] **Passo 2: escrever `lib/main.dart`**

```dart
import 'package:flutter/material.dart';

import 'app.dart';
import 'env.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Env.assertConfigured();
  runApp(const FlycommApp());
}
```

- [ ] **Passo 3: escrever `lib/app.dart`**

```dart
import 'package:flutter/material.dart';

import 'env.dart';
import 'history/audio_store.dart';
import 'history/database.dart';
import 'history/history_repository.dart';
import 'room/api_client.dart';
import 'room/auth_repository.dart';
import 'room/catchup_repository.dart';
import 'room/config_repository.dart';
import 'room/device_identity.dart';
import 'room/message_api.dart';
import 'room/room_repository.dart';
import 'room/server_clock.dart';
import 'ui/app_scope.dart';
import 'ui/rooms_screen.dart';

class FlycommApp extends StatelessWidget {
  const FlycommApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'flycomm',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B4965)),
          useMaterial3: true,
        ),
        home: const _Bootstrap(),
      );
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<AppScope> _ready = _start();

  /// A ordem importa: GET /config antes de tudo, porque é dele que saem os
  /// orçamentos, e ele sincroniza o relógio de saída.
  Future<AppScope> _start() async {
    final api = ApiClient(baseUrl: Env.httpBase);
    final clock = ServerClock();

    final config = await ConfigRepository(api: api, clock: clock).fetch();

    final auth = AuthRepository(api: api);
    final credentials = await DeviceIdentity().loadOrCreate();
    final user = await auth.authenticate(
      credentials,
      displayName: 'Piloto ${credentials.identifier.substring(8, 12)}',
    );

    final db = HistoryDatabase();

    return AppScope(
      api: api,
      clock: clock,
      config: config,
      auth: auth,
      rooms: RoomRepository(api: api),
      catchup: CatchupRepository(api: api, clock: clock),
      messageApi: MessageApi(api: api),
      history: HistoryRepository(db),
      audioStore: await AudioStore.open(),
      userId: user.id,
      child: DatabaseHolder(db: db, child: const RoomsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppScope>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'Não deu para falar com o servidor.\n\n${snapshot.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return snapshot.data!;
        },
      );
}
```

- [ ] **Passo 4: escrever `lib/ui/rooms_screen.dart`**

```dart
import 'package:flutter/material.dart';

import '../room/models.dart';
import 'app_scope.dart';
import 'room_screen.dart';

class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key});

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  late Future<List<Room>> _rooms;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rooms = AppScope.of(context).rooms.mine();
  }

  void _reload() => setState(() {
        _rooms = AppScope.of(context).rooms.mine();
      });

  Future<void> _joinByCode() async {
    final controller = TextEditingController();

    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Entrar por código'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            hintText: 'FLY-7K2M',
            helperText: 'Pode digitar sem hífen e em minúscula',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Entrar'),
          ),
        ],
      ),
    );

    if (code == null || code.isEmpty || !mounted) return;

    try {
      final room = await AppScope.of(context).rooms.join(code);
      if (!mounted) return;
      _reload();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RoomScreen(room: room)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Não deu para entrar: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Minhas salas')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _joinByCode,
          icon: const Icon(Icons.qr_code),
          label: const Text('Entrar por código'),
        ),
        body: FutureBuilder<List<Room>>(
          future: _rooms,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('Erro: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final rooms = snapshot.data!;
            if (rooms.isEmpty) {
              return const Center(
                child: Text('Nenhuma sala ainda.\nEntre por um código.',
                    textAlign: TextAlign.center),
              );
            }

            return RefreshIndicator(
              onRefresh: () async => _reload(),
              child: ListView.separated(
                itemCount: rooms.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final room = rooms[index];
                  return ListTile(
                    title: Text(room.name),
                    subtitle: Text(
                      '${room.members.length} piloto(s) · '
                      '${formatFrequency(room.frequencyHz)}',
                    ),
                    trailing: Text(room.inviteCode),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RoomScreen(room: room),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      );
}

/// A frequência é guardada como inteiro em Hz e só vira texto aqui.
/// Nula é um estado honesto: "ainda não combinamos a frequência".
String formatFrequency(int? hz) {
  if (hz == null) return 'sem frequência';
  return '${(hz / 1000000).toStringAsFixed(3)} MHz';
}
```

- [ ] **Passo 5: verificar**

```bash
flutter analyze
```

Esperado: só o erro de `room_screen.dart` ainda não existir. Ele some na Tarefa 21.

- [ ] **Passo 6: commit**

```bash
git add lib/main.dart lib/app.dart lib/ui/app_scope.dart lib/ui/rooms_screen.dart
git commit -m "feat: arranque do app e tela de salas com entrada por código"
```

---

## Tarefa 21: tela da sala, PTT e histórico

**Arquivos:**
- Criar: `lib/ui/ptt_button.dart`
- Criar: `lib/ui/message_tile.dart`
- Criar: `lib/ui/room_screen.dart`

- [ ] **Passo 1: escrever `lib/ui/ptt_button.dart`**

```dart
import 'package:flutter/material.dart';

/// Apertar e segurar. Grande de propósito: é operado em voo, às vezes de luva.
class PttButton extends StatefulWidget {
  const PttButton({
    super.key,
    required this.onPress,
    required this.onRelease,
    this.enabled = true,
  });

  final Future<void> Function() onPress;
  final Future<void> Function() onRelease;
  final bool enabled;

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton> {
  bool _held = false;

  Future<void> _press() async {
    if (!widget.enabled || _held) return;
    setState(() => _held = true);
    await widget.onPress();
  }

  Future<void> _release() async {
    if (!_held) return;
    setState(() => _held = false);
    await widget.onRelease();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return GestureDetector(
      onTapDown: (_) => _press(),
      onTapUp: (_) => _release(),
      onTapCancel: _release,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 140,
        decoration: BoxDecoration(
          color: !widget.enabled
              ? colors.surfaceContainerHighest
              : _held
                  ? colors.error
                  : colors.primary,
          borderRadius: BorderRadius.circular(24),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _held ? Icons.mic : Icons.mic_none,
              size: 44,
              color: colors.onPrimary,
            ),
            const SizedBox(height: 8),
            Text(
              _held ? 'FALANDO' : 'SEGURE PARA FALAR',
              style: TextStyle(
                color: colors.onPrimary,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Passo 2: escrever `lib/ui/message_tile.dart`**

```dart
import 'package:flutter/material.dart';

import '../history/database.dart';

/// Uma linha do histórico.
///
/// O estado é a informação mais importante da tela: **não entregue** significa
/// que ninguém ouviu o piloto, e ele precisa saber disso para pegar o rádio.
class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isMine,
    required this.onPlay,
  });

  final LocalMessage message;
  final bool isMine;
  final Future<void> Function() onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final seconds = (message.durationMs / 1000).toStringAsFixed(1);

    final (label, color, icon) = switch (message.state) {
      MessageState.recorded => ('gravada', colors.outline, Icons.fiber_manual_record),
      MessageState.sending => ('enviando…', colors.outline, Icons.upload),
      MessageState.delivered => ('entregue', colors.primary, Icons.check),
      MessageState.undelivered =>
        ('NÃO ENTREGUE — ninguém ouviu', colors.error, Icons.error_outline),
      MessageState.received => ('', colors.primary, Icons.volume_up),
      MessageState.late =>
        ('atrasada — toque para ouvir', colors.tertiary, Icons.history),
    };

    final author = isMine
        ? 'Você'
        : message.authorName ?? (message.origin == 'radio' ? 'Rádio' : 'sem nome');

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text('$author · $seconds s'),
      subtitle: label.isEmpty
          ? Text('segmento ${message.segmentIndex + 1}')
          : Text(label, style: TextStyle(color: color)),
      trailing: message.audioPath == null
          ? const Icon(Icons.cloud_off)
          : IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: onPlay,
              tooltip: 'Ouvir',
            ),
    );
  }
}
```

- [ ] **Passo 3: escrever `lib/ui/room_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../audio/player.dart';
import '../audio/recorder.dart';
import '../history/database.dart';
import '../room/models.dart';
import '../room/reverb_client.dart';
import '../room/room_session.dart';
import '../env.dart';
import 'app_scope.dart';
import 'message_tile.dart';
import 'ptt_button.dart';
import 'rooms_screen.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key, required this.room});

  final Room room;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  RoomSession? _session;
  String? _error;
  bool _micGranted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session == null) _open();
  }

  Future<void> _open() async {
    final scope = AppScope.of(context);

    _micGranted = await Permission.microphone.request().isGranted;

    final session = RoomSession(
      room: widget.room,
      budgets: scope.budgets,
      clock: scope.clock,
      reverb: ReverbClient(
        api: scope.api,
        appKey: Env.wsKey,
        host: Env.wsHost,
        port: Env.wsPort,
      ),
      catchup: scope.catchup,
      messageApi: scope.messageApi,
      history: scope.history,
      audioStore: scope.audioStore,
      recorder: PttRecorder(
        segmentMax: scope.budgets.segmentMax,
        serverNow: scope.clock.now,
      ),
      player: SegmentPlayer(),
    );

    session.gaps.listen((windowStart) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Houve um trecho que não deu para recuperar.'),
      ));
    });

    session.roomChanges.listen((_) {
      if (mounted) setState(() {});
    });

    try {
      await session.open();
      if (!mounted) return;
      setState(() => _session = session);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  Future<void> _editFrequency() async {
    final session = _session!;
    final scope = AppScope.of(context);
    final controller = TextEditingController(
      text: session.current.frequencyHz == null
          ? ''
          : (session.current.frequencyHz! / 1000000).toStringAsFixed(3),
    );

    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Frequência combinada'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            suffixText: 'MHz',
            helperText: 'Vazio limpa. Quem sintoniza o rádio é você.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );

    if (value == null || !mounted) return;

    // Hz inteiro, nunca float: o arredondamento acontece aqui, uma vez.
    final hz = value.isEmpty ? null : (double.tryParse(value)! * 1000000).round();

    if (hz != null && !scope.config.isFrequencyValid(hz)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Fora das faixas do rádio (136–174 e 400–470 MHz).'),
      ));
      return;
    }

    await scope.rooms.update(
      session.current.id,
      frequencyHz: hz,
      clearFrequency: hz == null,
    );
    // Não há setState aqui de propósito: a mudança volta por room.updated, e
    // é assim que ela chega em todo mundo sem recarregar.
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.room.name)),
        body: Center(child: Text('Não deu para abrir a sala.\n\n$_error')),
      );
    }

    final session = _session;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.room.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final scope = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(session.current.name),
        actions: [
          TextButton.icon(
            onPressed: _editFrequency,
            icon: const Icon(Icons.radio),
            label: Text(formatFrequency(session.current.frequencyHz)),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: StreamBuilder<RoomPresence>(
            stream: session.presence,
            builder: (context, snapshot) {
              final names = snapshot.data?.members
                      .map((m) => m.displayName)
                      .join(', ') ??
                  'conectando…';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 16, right: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Na sala: $names',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              );
            },
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<LocalMessage>>(
              stream: session.messages,
              builder: (context, snapshot) {
                final rows = snapshot.data ?? const <LocalMessage>[];
                if (rows.isEmpty) {
                  return const Center(child: Text('Nada dito ainda.'));
                }
                return ListView.separated(
                  reverse: false,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) => MessageTile(
                    message: rows[index],
                    isMine: rows[index].direction == MessageDirection.outgoing ||
                        rows[index].authorId == scope.userId,
                    onPlay: () => session.playFromHistory(rows[index].id),
                  ),
                );
              },
            ),
          ),
          if (!_micGranted)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Sem permissão de microfone: você só ouve.'),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: PttButton(
              enabled: _micGranted,
              onPress: session.pressPtt,
              onRelease: session.releasePtt,
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Passo 4: verificar**

```bash
flutter analyze && flutter test test/room test/audio test/history
```

Esperado: `No issues found!` e `All tests passed!`

- [ ] **Passo 5: rodar num emulador e ver a sala abrir**

```bash
flutter run --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Toque em "Entrar por código", digite `FLY-TEST`, e em outro terminal dispare:

```bash
cd ../flycomm-server && docker compose exec app php artisan flycomm:demo-burst 255 --from=510
```

Esperado: os três segmentos aparecem no histórico e tocam em sequência, um por vez.

- [ ] **Passo 6: commit**

```bash
git add lib/ui
git commit -m "feat: tela da sala com PTT, presença, frequência ao vivo e histórico"
```

---

## Tarefa 22: aceitação de dois dispositivos (seção 8 da spec)

Os cinco critérios de conclusão exigem dois dispositivos. Nenhum deles é verificável
por teste automatizado — são sobre o que o piloto ouve e vê.

**Arranjo:** um **emulador Android** e o **simulador iOS** no mesmo Mac. Os dois
alcançam `192.168.15.112` pela rota normal da LAN (`10.0.2.2` é só para o loopback do
host, e não serve aqui). Os dois usam o microfone do Mac, o que basta: o critério é
"falou em A, saiu em B".

Se o áudio do emulador Android atrapalhar, troque o emulador por um **iPhone físico na
mesma Wi-Fi** — `flutter run -d <id>` com assinatura de desenvolvedor gratuita, que
vale 7 dias e é suficiente.

> **Identidades distintas.** Cada `POST /auth/device` revoga o token anterior *daquele
> dispositivo*. Emulador e simulador geram pares próprios no primeiro uso
> (`DeviceIdentity`), então isso se resolve sozinho — **desde que os dois não sejam o
> mesmo emulador clonado**. Se um deles derrubar o outro, apague o app e reinstale
> para forçar um par novo.

**Arquivos:**
- Criar: `docs/fase-2-aceitacao.md`

- [ ] **Passo 1: subir os dois dispositivos**

```bash
flutter devices
```

Esperado: pelo menos dois, um Android e um iOS. Se faltar o Android:

```bash
flutter emulators --launch $(flutter emulators | awk 'NR==2{print $1}')
```

- [ ] **Passo 2: rodar o app nos dois, em dois terminais**

```bash
flutter run -d emulator-5554 --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

```bash
flutter run -d "iPhone 17 Pro" --dart-define=FLYCOMM_HTTP=http://192.168.15.112:8000 --dart-define=FLYCOMM_WS_HOST=192.168.15.112 --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Entre em `FLY-TEST` nos dois.

- [ ] **Passo 3: critério 1 — PTT em A, áudio em B, com a latência medida**

Segure o PTT em A por ~2 s e fale. Meça o intervalo entre soltar o PTT em A e o
começo do som em B (grave a tela dos dois, ou cronometre três vezes e tire a média).

Registre em `docs/fase-2-aceitacao.md`:

```markdown
# Fase 2 — aceitação (seção 8 da spec)

Data: <data> · Rede: <SSID> · Backend: <ip>:8000
Dispositivos: <A: modelo/SO> e <B: modelo/SO>

## 1. PTT em A, áudio toca em B

Latência ponta a ponta (soltar o PTT em A → primeiro som em B), 3 medidas:

| # | ms |
|---|---|
| 1 | |
| 2 | |
| 3 | |

Mediana: ___ ms. Observações:
```

- [ ] **Passo 4: critério 2 — fala de 12 s vira três mensagens, em ordem, sem buraco**

Segure o PTT em A por 12 s falando uma contagem em voz alta ("um, dois, três…" até
uns quarenta). Em B, confira:

- aparecem **três** linhas no histórico com o mesmo `burst_id`
- tocam na ordem 1, 2, 3, sem sobreposição
- a contagem não pula número na junção entre segmentos

Se pular número, o corte está tocando o áudio e não só o metadado — volte à Tarefa 11.

Registre:

```markdown
## 2. Fala de 12 s vira três mensagens

Segmentos observados: ___ · Em ordem: sim/não · Buraco audível: sim/não
```

- [ ] **Passo 5: critério 3 — modo avião em B por 20 s**

Com B na sala, ligue o modo avião em B. Em A, fale três vezes ao longo de 20 s.
Desligue o modo avião em B.

Esperado, e é onde as duas invariantes se encontram: o `catchup` traz o que ainda está
dentro de `playback_deadline` e **isso toca**; o que já passou do prazo entra no
histórico como **atrasada** e **não toca**.

Para forçar o segundo caso, espere 40 s antes de religar a rede.

Registre:

```markdown
## 3. Modo avião em B por 20 s

Mensagens que tocaram ao voltar: ___
Mensagens marcadas "atrasada" (não tocaram): ___
Toque numa atrasada reproduziu: sim/não
```

- [ ] **Passo 6: critério 4 — Wi-Fi desligado em A: NÃO ENTREGUE**

Desligue o Wi-Fi de A (ou ponha A em modo avião) e fale por ~3 s.

Esperado: a mensagem aparece no histórico de A como **NÃO ENTREGUE — ninguém ouviu**,
em vermelho, depois de no máximo `playback_deadline` (30 s). Ela **não** deve subir
quando a rede voltar: não existe fila de saída persistente.

Religue a rede e confirme que nada sobe retroativamente.

Registre:

```markdown
## 4. Wi-Fi desligado em A

Tempo até aparecer "não entregue": ___ s
Subiu sozinha quando a rede voltou: sim/não  (o esperado é NÃO)
```

- [ ] **Passo 7: critério 5 — frequência muda em A e aparece em B sem recarregar**

Em A, toque na frequência do topo e mude para `146.000`. Em B, sem tocar em nada,
confira que o valor no topo mudou.

Registre:

```markdown
## 5. Mudança de frequência

Apareceu em B sem recarregar: sim/não · Atraso aproximado: ___ s
```

- [ ] **Passo 8: commit do registro**

```bash
git add docs/fase-2-aceitacao.md
git commit -m "docs: registro da aceitação da Fase 2 com dois dispositivos"
```

---

## 23. O que fica em aberto ao fim da Fase 2

Registrado aqui para não se perder entre as fases:

- **A grafia de `format`** (seção 0.1). Precisa de um commit no repo `flycomm` antes
  de a Fase 3 fazer `format` decidir codificador.
- **Codec do caminho de dados** — continua aberta desde a spec anterior. O campo
  `format` é justamente o que permite adiar, e WAV sem compressão é caro em rede real:
  não pode ser esquecido antes da Fase 3.
- **A janela de retentativa do upload** (seção 0.2) é interpretação, não contrato.
  Calibrar em campo.
- **A recomendação de pacote da spec §5.7 está errada.** `pusher_channels_flutter`
  não alcança um Reverb próprio (ver Tarefa 13). A §5.7 ainda diz que ele é
  "compatível com Reverb" e que os ports Dart são "menos confiáveis" — precisa de um
  commit no repo `flycomm`, como a §5.7 é parte da spec compartilhada.
- **`-j 1` nos testes de integração** é consequência de o servidor revogar o token
  anterior a cada `POST /auth/device`. Se um dia as credenciais de teste deixarem de
  ser compartilhadas entre arquivos, a restrição cai.
- **Segundo plano** é Fase 4: hoje o app só funciona com a tela acesa, e isso é
  esperado.

---

## 24. Autorrevisão do plano contra a spec

| Seção da spec | Onde está no plano |
|---|---|
| 2 — orçamentos, medidos contra o relógio do servidor | Tarefas 4, 5, 6 |
| 2.1 — descarte por prazo, catch-up, sem fila de saída | Tarefas 12, 14, 16 |
| 3 — sala plana, frequência em Hz nullable, código curto | Tarefas 8, 20, 21 |
| 4 — identidade é o user, credencial é anexo | Tarefa 7 |
| 5 / 5.1 — segmentação de 5 s, PCM 16 kHz em WAV | Tarefas 10, 11, 17 |
| 6.2 / 6.2.1 — as dez rotas e o contrato de requisição | Tarefas 6, 7, 8, 14, 15 |
| 6.3 — eventos e o formato único de mensagem | Tarefas 8, 13 |
| 7 — módulos, gravação, reprodução, estados, histórico | Tarefas 9, 12, 17, 18, 19, 21 |
| 8 — os cinco critérios de conclusão | Tarefa 22 |
| 10 — schema do SQLite, design de UI da sala | Tarefas 9, 20, 21 (fechadas aqui) |

Fora do escopo e deliberadamente ausentes: BLE, ponte e eleição, segundo plano, PTT
externo. Nenhum diretório vazio é criado para eles.
