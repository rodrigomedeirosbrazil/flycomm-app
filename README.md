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

**Falar apertando o fone Bluetooth** funciona nas duas plataformas, e as duas
são espelhos invertidos uma da outra com a tela bloqueada: o **Android** grava e
envia normalmente; o **iPhone** recebe o gesto e toca os avisos, mas não grava.
Não é defeito nosso e não tem contorno — o iOS proíbe *iniciar* gravação com o
app em segundo plano (`CMSession: Client is in the background and doesn't have
the entitlement to start recording in the background`), e não existe chave de
`Info.plist` que libere. Quando isso acontece o app toca um bipe grave duplo e
guarda o motivo num aviso que fica na tela até ser dispensado, porque um piloto
de tela apagada não tem outro jeito de saber que ninguém o ouviu.

O caminho sancionado é o framework PushToTalk (iOS 16+), que existe exatamente
para isto e já está registrado como Fase 5 — exige capability, conta paga e
APNs. Enquanto ele não entra, PTT com a tela bloqueada é recurso de Android.

Resumindo a inversão: com a tela apagada o iPhone **ouve** e não fala, o Android
**fala** e não ouve.

### O que o piloto alcança pela interface

O app começou expondo menos do que o cliente sabia fazer. Hoje tem:

- **Configuração** — o nome de exibição, que antes era sorteado no arranque e
  permanente; mais o diagnóstico de campo (servidor, desvio do relógio, os
  orçamentos do `GET /config`) e o log de botões de mídia.
- **Salas** — criar, entrar por código, renomear, sair, e ler o código de
  convite de dentro da sala, que é onde se está quando perguntam por ele pelo
  rádio.
- **Quem está ouvindo** — a barra de presença abre a lista dos pilotos, com a
  distinção que importa: quem não está na presença não te ouve ao vivo. Com o
  próprio socket caído ela diz que **não sabe**, em vez de mostrar a lista
  velha.
- **Quem está falando** — o card da fala em curso se destaca inteiro.

Ver a [spec](docs/superpowers/specs/2026-09-14-config-e-usabilidade-design.md) e
o [plano](docs/superpowers/plans/2026-09-14-config-e-usabilidade.md) desta
rodada. Nada ali mudou o contrato com o servidor.

### Os documentos que explicam o porquê

O [plano da Fase 2](docs/superpowers/plans/2026-09-13-fase-2-app-flutter.md) é o
mais útil para entender cada decisão: ele carrega o contrato verificado contra o
servidor real, as divergências encontradas e as armadilhas que só aparecem no
aparelho.

A [aceitação](docs/fase-2-aceitacao.md) registra o que foi medido — inclusive um
critério que passou por sorte de temporização e foi corrigido depois, quando o
defeito que ele deveria ter pego apareceu em voo.

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

O WebSocket sobe `wss` sempre que `FLYCOMM_HTTP` é `https` — não existe define
próprio para o esquema do socket, ele é derivado de `FLYCOMM_HTTP`
([lib/env.dart](lib/env.dart)), porque API e Reverb atravessam a mesma borda e
os dois esquemas sempre sobem juntos.

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

## Produção

O APK que sai do workflow de release (`.github/workflows/release.yml`) já vem
apontado para `https://flycomm.medeirostec.com.br`, na 443, HTTP e WebSocket
(Reverb) no mesmo host — nenhum passo manual depois de instalar. A
`REVERB_APP_KEY` vem do secret do repositório `FLYCOMM_REVERB_APP_KEY`
(o mesmo valor de `REVERB_APP_KEY` em `~/flycomm/.env` na VPS); o job falha
alto se ele estiver vazio, em vez de publicar um APK que não abre.

### Compilar produção da sua máquina

O CI só monta Android. iOS sai daqui, pelo cabo — e volta e meia é preciso um
APK de produção local também. Para não digitar os quatro defines na mão (e
errar um deles em silêncio), eles moram num arquivo:

```bash
flutter build ios --release --dart-define-from-file=flycomm-prod.json
flutter build apk --release --dart-define-from-file=flycomm-prod.json
```

`flycomm-prod.json` **não está no repositório e não pode entrar** — ele carrega
a `REVERB_APP_KEY`. O `.gitignore` cobre `flycomm-*.json` e abre exceção para
`flycomm-*.example.json`; copie o exemplo e preencha a chave:

```bash
cp flycomm-prod.example.json flycomm-prod.json   # e edite FLYCOMM_WS_KEY
```

Seja honesto sobre o que isso protege. A chave vai embutida no APK e aparece na
URL de conexão do Reverb — quem tem o arquivo instalado tem a chave, e o
`.gitignore` não muda isso. O que ele evita é ela entrar no **histórico do
git**, que é o único lugar de onde tirar depois é caro. O arquivo em texto na
sua máquina é aceitável; no histórico do repositório, não.

O mesmo vale para builds locais: se você cansar de repetir os defines do
servidor de bancada, um `flycomm-local.json` com os valores da sua LAN também é
ignorado pela mesma regra.

O banco de produção não roda seed: não existem os dispositivos
`demo-device-*` nem os convites `FLY-TEST`/`FLY-2FLY` que
`test/integration/env.dart` usa — os testes de integração continuam
apontando para o servidor local.

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
