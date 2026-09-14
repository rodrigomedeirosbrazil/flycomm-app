# flycomm-app

App Flutter da sala de pilotos do projeto flycomm. Conversa com o backend
[flycomm-server](../flycomm-server) e, a partir da Fase 3, com a ponte ESP32 do
repositório [flycomm](../flycomm), que também é a fonte canônica das specs.

**Escopo atual — Fase 2:** sala, presença, PTT, fila FIFO de reprodução e
histórico local em SQLite. Sem BLE, sem rádio, sem segundo plano.

## Specs

- [Fase 2 — sala e backend](docs/specs/2026-09-13-fase-2-sala-e-backend-design.md) ← o que estamos construindo
- [Sistema completo](docs/specs/2026-09-12-app-piloto-sala-radio-design.md) — contexto e fases seguintes

Cópias verbatim; a origem é o `flycomm`. Ver [docs/specs/README.md](docs/specs/README.md).

## Estado

Fase 2 implementada e rodando em **iPhone, Android e simulador** contra o
backend real. Quatro dos seis critérios de conclusão da seção 8 da spec estão
cumpridos — ver [docs/fase-2-aceitacao.md](docs/fase-2-aceitacao.md) para o que
foi medido e o que falta.

A fatia antecipada da §7.1 — **escuta em segundo plano no iOS** — funciona: com
a tela bloqueada o WebSocket sobrevive, a fala chega ao vivo em centenas de
milissegundos e o som sai. Ela depende de um andaime (silêncio em laço) que sai
quando o framework PushToTalk entrar, na Fase 5. **No Android isso não vale**:
lá a escuta em segundo plano precisa de Foreground Service, que é Fase 4.

O [plano de implementação](docs/superpowers/plans/2026-09-13-fase-2-app-flutter.md)
é o documento mais útil para entender o porquê de cada decisão: ele carrega o
contrato verificado contra o servidor real, as divergências encontradas e as
armadilhas que só aparecem no aparelho.

## Como rodar

O app se desenvolve contra o `flycomm-server` rodando de verdade, nunca contra
mocks. Suba o backend (`docker compose up -d` no `flycomm-server`) e descubra o
IP da sua máquina na LAN — ele muda de rede para rede, e por isso nunca é
constante no código:

```bash
flutter run \
  --dart-define=FLYCOMM_HTTP=http://SEU_IP:8000 \
  --dart-define=FLYCOMM_WS_HOST=SEU_IP \
  --dart-define=FLYCOMM_WS_PORT=8080 \
  --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

Testes de unidade, sem servidor e sem emulador:

```bash
flutter test test/room test/audio test/history
```

Testes de integração, contra o servidor de verdade. O `-j 1` não é opcional:
cada `POST /auth/device` revoga o token anterior daquele dispositivo, e os
arquivos compartilham as credenciais semeadas — em paralelo eles se deslogam
mutuamente.

```bash
flutter test test/integration -j 1 --dart-define=... # os mesmos quatro defines
```

`flutter analyze` limpo e testes passando **não** provam que o app monta nem que
ele funciona no aparelho. Antes de dar qualquer coisa por pronta, rode também
`flutter build ios --release` (ou `apk`) e abra no celular: os defeitos mais
caros desta fase só apareceram assim.

## Instalar no aparelho

`flutter run` é para desenvolver com o computador por perto. Para deixar o app
**no** celular — para voar com ele, ou para você testar sozinho — é outro
caminho, e ele tem três armadilhas que já custaram uma noite cada.

Compile em **release**, com os quatro defines, e instale por cima:

```bash
# Android
flutter build apk --release --dart-define=FLYCOMM_HTTP=http://SEU_IP:8000 --dart-define=FLYCOMM_WS_HOST=SEU_IP --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

```bash
# iPhone
flutter build ios --release --dart-define=FLYCOMM_HTTP=http://SEU_IP:8000 --dart-define=FLYCOMM_WS_HOST=SEU_IP --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
xcrun devicectl device install app --device SEU_UDID build/ios/iphoneos/Runner.app
```

**Não use `flutter install`.** Ele faz duas coisas ruins de uma vez: não
compila — manda para o aparelho o último build que estiver em `build/`, que
pode ser de horas atrás — e **desinstala a versão antiga antes de instalar**,
o que no iOS leva junto o diretório de dados do app. O histórico é 100% local e
permanente, e o servidor não tem cópia: desinstalar é apagá-lo para sempre.
`adb install -r` e `devicectl install` substituem sem apagar. No Android isso só
vale porque o release é assinado com a mesma chave de debug (ver
`android/app/build.gradle.kts`); trocar por uma chave de verdade obriga a
desinstalar, e aí o histórico vai junto.

**Debug não abre sozinho no iPhone.** Um `.app` debug roda em JIT, e o iOS
recusa lançar isso fora do tooling — a tela fica em branco com um aviso de que
apps em debug só devem ser lançados pelo Flutter. Release resolve, com o preço
de que o `trace()` é `assert` e **some**: nada de narração no logcat sobre pico
de captura, idade da fala ou decisão de tocar. Quando precisar desse rastro, é
`flutter run --debug` com os mesmos defines.

**Os defines somem se você não olhar.** Sem eles o app aborta na primeira linha
do `main` e a tela fica em branco — de propósito, e o motivo aparece inteiro no
log:

```bash
adb logcat -d | grep '^[EW]/flutter'   # Android
xcrun devicectl device process launch --console --device SEU_UDID br.com.medeirostec.flycomm
```

Um detalhe de shell que já mordeu aqui: **não** guarde os defines numa variável
e a expanda sem aspas. O zsh não divide parâmetros em palavras, e os quatro
flags viram um define só, com o resto da linha dentro do valor do primeiro. O
sintoma é enganoso — o log reclama de três defines faltando, depois de dois, e
o que "passou" está com lixo dentro. Escreva os flags literalmente.

## Nota sobre credenciais

Os valores que aparecem no plano e nos testes (`demo-device-*`, `demo-secret-*`,
`flycomm-local-key`, IPs `192.168.*`) são de bancada: dispositivos semeados pelo
`docker compose` local e a chave padrão do Reverb em desenvolvimento. Não dão
acesso a nada. Se um dia houver ambiente publicado, ele precisa de chave própria
— reaproveitar estes valores seria transformar exemplo em segredo de verdade.
