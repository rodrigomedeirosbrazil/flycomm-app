# Fase 2 — aceitação (seção 8 da spec)

Data: 2026-09-13 · Backend: `192.168.15.112:8000` (Reverb em `:8080`)

Dispositivos:

- **A** — iPhone de Rodrigo, iOS 26.6.2, build release assinado (`br.com.medeirostec.flycomm`)
- **B** — Simulador iPhone 17 Pro, iOS 26.5, build debug

Sala: **Voo de domingo** (`FLY-TEST`). O servidor foi re-semeado durante a
revisão da spec; a sala passou a ser **id 1**.

---

## 1. PTT em A, áudio toca em B — **cumprido**

Fala de 2,6 s no iPhone, recebida e tocada no simulador.

| Campo | Valor |
|---|---|
| `duration_ms` | 2584 |
| `size_bytes` | 82 752 |
| `format` | `wav-pcm16-16k` |
| `captured_at` (cliente) | `18:20:52` |
| `created_at` (servidor) | `18:20:53` |
| `POST /rooms/{id}/messages` | 201, 431,8 ms no servidor |
| `GET /messages/{id}/audio` (por B) | 200, 12,6 ms |

A aritmética do WAV fecha: 82 752 − 44 de cabeçalho = 82 708 bytes de PCM;
82 708 ÷ 32 bytes/ms = 2584 ms, exatamente o `duration_ms` gravado. A duração vem
da contagem de bytes, não de um cronômetro.

**Latência ponta a ponta: ~1 s, e essa precisão é o melhor que dá hoje.**

O critério pede a latência medida e registrada, mas `messages.created_at` tem
**resolução de segundo** — `captured_at` e `created_at` chegam como `.000000`. Contra
o prazo de 30 s um erro de ±1 s é irrelevante (3%), mas para *medir latência* é grosso
demais: o número real está em algum ponto entre 0,5 s e 1,5 s e não dá para estreitar
com os carimbos que existem.

Fica registrado como **medição aproximada**, não como número confiável. Para medir de
verdade seria preciso ou `created_at` com sub-segundo no servidor, ou instrumentar o
app para carimbar o instante em que a reprodução começa e comparar com `captured_at`
pelo relógio do servidor. A segunda opção não depende de mudar o contrato.

## 2. Fala de 12 s vira três mensagens — **cumprido**

Fala de ~14,5 s no iPhone, com contagem em voz alta.

| index | `duration_ms` | `size_bytes` | `created_at` |
|---|---|---|---|
| 0 | 5000 | 160 044 | 18:25:29 |
| 1 | 5000 | 160 044 | 18:25:34 |
| 2 | 4484 | 143 552 | 18:25:38 |

Mesmo `burst_id`, índices contíguos, total 14 484 ms. Os tamanhos fecham na régua de
32 bytes/ms (160 044 = 44 de cabeçalho + 5000 × 32).

Tocaram em ordem no simulador, e **a contagem saiu inteira, sem buraco nas junções** —
confirmado de ouvido, que é o único jeito de confirmar isto. O corte foi no metadado e
não no áudio.

O que os carimbos mostram além do pedido: os três segmentos subiram com ~5 s de
intervalo, **enquanto o piloto ainda falava**. O segmento 0 foi ao servidor aos 5 s do
aperto, não no momento de soltar. A captura não parou para fechar segmento.

## 3. Modo avião em B por 20 s — **pendente**

Observação lateral já obtida: ao entrar na sala às 15:20, os três segmentos publicados
às 15:11 **não tocaram**. Passaram do `playback_deadline` (30 s) e os blobs já tinham
vencido (`blob_ttl` de 5 min). Áudio velho não toca sozinho — a invariante da seção 2.1
vale, ainda que por um caminho diferente do que o critério 3 pede.

## 4. Wi-Fi desligado em A e religado dentro do `delivery_deadline` — **cumprido**

A spec foi revista (commit `a447aab` no `flycomm`): a mensagem vencida agora **sobe**,
não toca em ninguém, aparece como **atrasada** e é encaixada onde foi **gravada**.

O lado receptor foi verificado sem os dois aparelhos, publicando direto na API: uma
fala fresca e, **depois**, uma de 2 minutos atrás.

| Ordem de chegada | `captured_at` | Como apareceu |
|---|---|---|
| 1ª | agora | topo, alto-falante — tocou |
| 2ª | −2 min | **abaixo** da fresca, "atrasada — toque para ouvir" — não tocou |

A atrasada chegou depois e ficou embaixo: a ordenação é por `captured_at`, não por
chegada. É o comportamento que a §2.1 descreve.

Depois, com os dois aparelhos de verdade. O iPhone em modo avião gravou uma fala de
2084 ms e insistiu até a rede voltar:

| | |
|---|---|
| Falou (`captured_at`) | 19:50:48, em modo avião |
| Chegou (`created_at`) | 19:51:50 |
| **Atraso** | **62 s** |

Sessenta e dois segundos. Sob o comportamento anterior a mensagem teria sido
abandonada aos 30 s e ninguém saberia que o piloto falou.

No simulador ela entrou como **atrasada**, sem tocar, e no **topo** da lista — porque
foi a fala mais recente, embora tenha sido a última a chegar. Abaixo dela, uma fala de
19:48:59 que chegou antes. A linha do tempo é da conversa, não do transporte.

No iPhone, a linha ficou como **entregue atrasada**, confirmado pelo piloto: o estado
que a §7 criou para dizer "entrou no registro dos outros, mas ninguém te ouviu ao
vivo".

## 4b. Wi-Fi desligado além do `delivery_deadline` — **pendente**

Exige ficar offline mais de 5 minutos.

## 5. Mudança de frequência — **cumprido**

Alterada de 145,550 para 146,000 MHz no iPhone (`PATCH /rooms/255` → 200). O
simulador passou a mostrar **146.000 MHz** sem nenhum toque e sem recarregar: só o
evento `room.updated` chegando pelo presence channel.

Achado no caminho, corrigido antes de passar — o editor de frequência tinha três
defeitos que só o uso real expõe:

1. `double.tryParse(value)!` derrubava o app com entrada não parseável. O teclado
   decimal do iOS em pt-BR usa **vírgula**, então `145,550` virava `null` e o `!`
   crashava. Nunca usar `!` no que veio de teclado.
2. Vírgula não era normalizada para ponto — o formato natural em português não
   funcionava.
3. A ajuda não dizia unidade nem faixas, então digitar `146000` querendo dizer
   `146,000` parecia razoável, e o erro não dava pista do mal-entendido. Agora a
   mensagem repete o valor entendido.

---

## Observações que valem para além dos critérios

**As duas grafias de `format` convivem.** As mensagens do app são `wav-pcm16-16k` (o
que a spec manda) e as da rajada de demonstração são `wav/pcm16/16000` (o que o
servidor escreve). As duas tocaram, porque o app decodifica WAV sempre e não condiciona
reprodução ao campo. Continua precisando de decisão no repo `flycomm` antes da Fase 3,
quando `format` passa a escolher decodificador.

**Presença funciona sem recarregar.** O simulador passou de "Na sala: Piloto 546f" para
"Piloto 546f, Piloto 4f48" no instante em que o iPhone assinou o canal.

**Identidades são por aparelho.** iPhone e simulador geraram credenciais próprias no
primeiro uso e viraram dois usuários distintos, sem nenhum passo manual.

**Identidade sobrevive à reinstalação; histórico não.** Reinstalar o app no iPhone
devolveu `200` em `POST /auth/device` em vez de `201`: o par identifier/secret ficou
no Keychain e o piloto continuou o mesmo, com as mesmas salas. Já o histórico local
foi junto com o SQLite do app.

A assimetria é consequência direta do desenho — o servidor é transporte e não repõe
histórico —, mas é o tipo de coisa que surpreende em campo: "reinstalei e perdi as
conversas, mas continuo sendo eu". Vale uma linha na UI quando a Fase 2 virar produto.

**Três dos bugs encontrados hoje não eram alcançáveis por teste automatizado:**
o `AppScope` abaixo do `MaterialApp` (só aparece ao abrir a segunda tela), a falta de
`NSLocalNetworkUsageDescription` (o simulador não impõe a regra) e o `!` no parse da
frequência (depende do separador decimal da localidade). Nenhum foi pego por 42 testes
de unidade, 22 de integração ou `flutter analyze` limpo. É o argumento de que esta
seção 8 não é opcional.

---

## 7.1 Escuta em segundo plano no iOS — **investigação (conclusão revista abaixo)**

> A conclusão desta seção foi **superada** pela revisão no fim do documento: com
> o `APP_URL` dos containers corrigido, a escuta em segundo plano funciona. A
> investigação fica registrada inteira porque o caminho errado é a parte útil —
> ele mostra como um defeito de configuração do servidor se disfarçou de limite
> do iOS por horas.

A fatia antecipada da Fase 4 (§7.1 da spec). Duas tentativas, e a primeira falhou de
um jeito instrutivo.

**Tentativa 1 — `UIBackgroundModes: audio` + sessão ativa. Falhou.**

Com a tela bloqueada, a fala publicada chegou assim:

```
201  POST /rooms/1/messages
200  POST /broadcasting/auth       ← reconexão
200  GET  /rooms/1/catchup
200  GET  /messages/.../audio
```

O download veio **depois** de um `broadcasting/auth`: o aparelho reconectou ao
desbloquear e pegou a mensagem pelo catch-up, já vencida, marcada *atrasada*. Não
recebeu ao vivo. O app tinha sido suspenso.

Causa: `UIBackgroundModes: audio` mantém o app vivo **enquanto ele está de fato
produzindo áudio**. Sessão ativa mas silenciosa não segura nada — e o caso do flycomm
é o silencioso, porque esperar alguém falar é o oposto de tocar.

**Tentativa 2 — silêncio em laço. Conexão sobreviveu.**

```
20:11:24   catchup + broadcasting/auth + catchup   entrada na sala, tela ligada
20:11:49   GET /messages/35da3385/audio            25 s depois, SEM auth no meio
```

Sem `broadcasting/auth` entre a publicação e o download: não houve reconexão. O
WebSocket estava vivo com a tela bloqueada, recebeu o `message.new` e baixou o áudio.
**O processo sobreviveu ao segundo plano.**

O que ainda falta confirmar: se o som sai no alto-falante. Conexão viva e áudio
audível são duas perguntas separadas, e a primeira era a difícil.

**O teste que ainda não foi feito** é o que a Fase 4 chama de verdadeiro: uma hora com
o celular no bolso. Ele responde se o iOS sustenta isto ou derruba depois de um tempo,
e é a resposta que a Fase 3 precisa antes de desenhar a eleição de ponte.

**O silêncio em laço é andaime, não solução.** Gasta bateria continuamente e a Apple
desencoraja, sendo motivo conhecido de recusa na App Store. Decisão registrada: o iOS
não vai para a loja por ora; quando for, troca-se pelo framework PushToTalk, que a
spec do sistema já previa como Fase 5.

### Armadilhas que só o aparelho revela

Três desta fase, todas invisíveis no simulador e todas com o mesmo formato — o
simulador é generoso onde o iOS é estrito:

| Armadilha | No simulador | No aparelho |
|---|---|---|
| `NSLocalNetworkUsageDescription` ausente | funciona | não alcança a LAN, sem pedir permissão |
| `APP_URL=localhost` no servidor | funciona, porque `localhost` é o Mac | `audio_url` aponta para o próprio celular: Connection refused |
| Conexão reaproveitada do pool | raro, app em primeiro plano | `ApiException(null): connection reused` ao voltar do segundo plano |

A lição operacional: **o simulador não é evidência para nada que envolva rede ou
ciclo de vida.** Serve para UI e lógica; o resto exige o aparelho.

### Desfecho: o andaime não sustenta

Depois da tentativa 2 funcionar uma vez, ela não se repetiu. O teste decisivo eliminou
a última variável: **dados móveis desligados**, para o aparelho só poder usar o Wi-Fi
— o servidor está num IP privado e a Assistência Wi-Fi do iOS trocando para o 4G o
tornaria inalcançável por um motivo alheio ao segundo plano.

Com Wi-Fi garantido, a fala publicada não foi buscada. E ao reabrir, o log mostrou
`GET /config` + `POST /auth/device` + `GET /rooms`: **partida a frio**. O app tinha
sido morto, não apenas desconectado.

| Tentativa | Resultado |
|---|---|
| Sessão ativa, sem áudio saindo | suspenso em segundos |
| Silêncio em laço | funcionou **uma vez** (3 entregas ao vivo, 41 s de intervalo), não se repetiu |
| Silêncio em laço, Wi-Fi garantido | **morto em segundo plano** |

**O intermitente é o pior desfecho possível.** Um rádio que às vezes ouve é mais
perigoso que um que nunca ouve: o piloto guarda o celular confiando nele, e a falha só
aparece quando alguém precisou e não foi ouvido.

### O que isto decide

**A premissa da Fase 3 estava errada, e agora está medida.** A eleição de ponte não
pode assumir que o celular no bolso continua ouvindo. Era exatamente para descobrir
isso que a fatia foi antecipada (§7.1 da spec), e o custo de descobrir agora foi uma
tarde; no meio da Fase 3, com BLE e supressão de eco sendo depurados ao mesmo tempo,
teria sido muito maior.

**O caminho é o framework PushToTalk** (iOS 16+), que a spec do sistema já registrava
como Fase 5 — agora com justificativa medida em vez de teórica. Ele exige entitlement
`com.apple.developer.push-to-talk`, conta paga de desenvolvedor e APNs.

**O silêncio em laço deveria sair.** Ele gasta bateria continuamente para entregar uma
garantia que não existe, e deixá-lo no código convida alguém a confiar nele.

---

## 7.1 — revisão: com o `APP_URL` corrigido, a escuta em segundo plano funciona

Data: 2026-09-13, 22:25 · confirmado de ouvido pelo piloto: **o som sai**.

A conclusão acima foi escrita antes de a última armadilha ser encontrada. Entre
ela e esta seção mudaram quatro coisas, e é honesto não saber qual pesou mais:

1. **`APP_URL` assado nos containers.** O `compose.yaml` usa `env_file:`, que
   injeta o ambiente **na criação** do container — `docker compose restart` não
   relê. O `.env` corrigido só valia para o container `app`, recriado por
   acidente; `queue` e `reverb` continuavam com `http://localhost:8000`. E o
   evento `message.new` é serializado no **worker da fila**. Resultado: quem
   recebia pelo WebSocket recebia uma `audio_url` apontando para o próprio
   celular; quem recebia pelo catch-up (REST) recebia o IP certo. Isso explica
   retroativamente o "funcionou uma vez e não se repetiu": não era o iOS
   oscilando, era o caminho da entrega mudando.
2. `just_audio`: `stop()` libera o decodificador nativo — a segunda fala em
   diante falhava e virava "atrasada" (commit `b0612a4`).
3. Ingest duplicado, quando evento e catch-up chegavam a 132 ms um do outro.
4. Segunda chance para a mensagem cujo áudio falhou ao baixar (`7175248`).

### O que o log do servidor mostra

Um `GET /messages/{id}/audio` **sem `POST /broadcasting/auth` antes** significa
que não houve reconexão: o WebSocket estava vivo e o `message.new` chegou ao
vivo. Com `broadcasting/auth` + `catchup` no meio, o aparelho tinha caído e
pegou a fala pelo catch-up.

| Publicação | Download | Intervalo | Reconectou? |
|---|---|---|---|
| 22:25:11.665 | 22:25:12.047 | **382 ms** | não |
| 22:25:29.031 | 22:25:34.855 | 5,8 s | **sim** (auth + catchup) |
| 22:25:46.599 | 22:25:46.761 | **162 ms** | não |
| 22:26:30.820 | 22:26:31.024 | **204 ms** | não |

Três entregas ao vivo em quatro, a última depois de **44 s de conexão ociosa**.
Entrega ao vivo em centenas de milissegundos, contra os 5,8 s do caminho por
catch-up — a diferença entre um rádio e uma caixa de mensagens.

### O que isto muda, e o que não muda

**Muda:** o silêncio em laço **fica**. A recomendação anterior de removê-lo
partia de que ele gastava bateria sem entregar garantia nenhuma; ele entrega.
Sai quando o framework PushToTalk entrar (Fase 5), não antes.

**Não muda:** a entrega não é de 100% — uma das quatro reconectou. Para um rádio
isso ainda não é "resolvido", é "funciona na maior parte das vezes", e a
diferença importa quando alguém precisa ser ouvido e não é.

**Não muda:** o teste de uma hora com o celular no bolso continua por fazer. É
ele que diz se o iOS sustenta ou derruba depois de um tempo, e é a resposta que
a Fase 3 precisa antes de desenhar a eleição de ponte. Quatro entregas em 80
segundos não respondem isso.

**Não muda no Android:** nada disto vale lá. A escuta em segundo plano no
Android depende de Foreground Service, que é Fase 4. A barra "Entrar em voo"
aparece nas duas plataformas e só cumpre o que promete no iOS — decisão em
aberto: escondê-la no Android, ou rotulá-la de outro jeito.

### A lição de método

O que resolveu foi **pôr o destino em toda mensagem de erro de rede**, uma
mudança de uma linha em [`api_client.dart`](../lib/room/api_client.dart):

```
ApiException(null): Connection refused
ApiException(null): Connection refused [http://localhost:8000/messages/.../audio]
```

A primeira forma me fez perseguir rede, sessão de áudio, ciclo de vida do app e
ciclo de vida do player, por horas. A segunda respondeu na primeira tentativa.

O mesmo princípio virou código: [`lib/room/trace.dart`](../lib/room/trace.dart)
narra ingest → download → disco → fila → reprodução, só em debug. O sintoma
"todas as mensagens chegam atrasadas e não tocam" teve **três causas diferentes**
nesta sessão, e nenhuma delas era visível no log do servidor — ele é cego para
tudo o que acontece dentro do app.

---

## Captura no Android: o microfone principal do aparelho de bancada não grava

Data: 2026-09-13 · Galaxy A12 (SM-A125M, MediaTek MT6765), Android 12

Sintoma relatado: "o áudio enviado pelo Android está mudo". Resolvido, mas o
caminho até a causa é mais útil que a correção, porque ela tem uma linha e a
investigação teve seis tentativas erradas.

### A correção

`AndroidRecordConfig(audioSource: AndroidAudioSource.camcorder)`.

### O que a medição mostrou

Varredura num app isolado — só o pacote `record`, sem `audio_session`, sem
player, sem nada do flycomm. Seis gravações de 3 s seguidas, mesma voz, mesma
distância:

| fonte | taxa | pico | modulação | 100–1k Hz | veredito |
|---|---|---|---|---|---|
| `defaultSource` | 16 kHz | 388 | 0,257 | 46,2% | ruído |
| `defaultSource` | 48 kHz | 129 | 0,276 | 21,4% | ruído |
| `mic` | 44,1 kHz | 118 | 0,273 | 22,7% | ruído |
| `unprocessed` | 48 kHz | 6 | 0,040 | 9,0% | mudo |
| `voiceRecognition` | 48 kHz | 71 | 0,120 | 13,1% | ruído |
| **`camcorder`** | 48 kHz | **32767** | **0,887** | **59,7%** | **FALA** |

Todas as fontes que falharam usam o microfone **principal**; a única que
funcionou usa o **secundário**, o de perto da câmera. O microfone principal
deste aparelho não entrega áudio.

### Por que seis tentativas antes disso falharam

Todas partiam de "chega baixo" e mexiam em nível. Não havia sinal para
amplificar:

| tentativa | resultado |
|---|---|
| `autoGain` (efeito `AutomaticGainControl`) | +2 dB e mais chiado |
| fonte `voiceCommunication` | piorou: pico 363 → 146 |
| captura a 48 kHz nativos | piorou: pico → 112 |
| ganho digital nosso, +18 a +30 dB | amplificou ruído |
| subtração espectral | **nenhuma palavra recuperada** |

A subtração espectral foi o que finalmente fechou a questão: ela não recupera o
que não foi gravado. Quando o piloto disse que o arquivo "recuperado" não tinha
nada para escutar, a pergunta deixou de ser "por que está baixo" e passou a ser
"a voz está aqui?".

### Os instrumentos que faltavam

**`peakAmplitudeOfPcm`** ([wav.dart](../lib/audio/wav.dart)). `duration_ms` e
`size_bytes` saem da contagem de bytes e são **idênticos** para um segmento com
fala e um mudo — uma gravação que não captou nada sobe com metadado impecável.
Foi por isso que este defeito atravessou toda a seção 8 sem aparecer.

**A comparação controlada.** O histórico local guarda as duas pontas. Com
`direction` no SQLite do aparelho: `received` (gravado no iPhone) deu pico
9134; `delivered` (gravado ali) deu 146 a 456. Mesma sala, mesmo app, mesmo
armazenamento — 26 a 30 dB de diferença, e nenhuma configuração mexeu nisso.

**A modulação.** Pico sozinho não distingue fala fraca de ruído. O desvio da
energia sobre a média separa: ruído fica abaixo de 0,15, fala passa de 0,6. Foi
essa métrica que condenou a `voiceCommunication` (0,051, envelope chato) e
absolveu a `camcorder` (0,887).

### Erros de leitura cometidos e corrigidos no caminho

- `bt_a2dp` listado como "Current" no `dumpsys audio` foi lido como rota ativa.
  Era a tabela de volumes por dispositivo; o Bluetooth estava desconectado.
- `openInputStream sampleRate = 8000` quase virou "taxa errada". Havia dois
  streams abertos; o nosso era o de 16000, identificável pelo
  `com.llfbandit.record` pedindo e devolvendo foco em volta do segmento.
- O envelope subindo de 55 a 363 foi lido como prova de fala. Era rampa de
  aquecimento seguida de oscilação rasa — não prova nada.

### O que fica em aberto

**Isto é uma medição em UM aparelho, provavelmente defeituoso.** `camcorder`
usa um microfone mais distante da boca e afinado para captação ampla; não é a
escolha certa para um rádio num celular são. Antes de virar padrão, a mesma
varredura precisa rodar num segundo Android.

**A saída boa é escolher a fonte medindo, não fixando.** Já existe
`peakAmplitudeOfPcm`: gravar, olhar o pico, e cair para outra fonte quando vier
silêncio funciona em qualquer aparelho.

**Tela de configuração de microfone** — pedida pelo piloto ao ver este
resultado, e é a conclusão certa: se o aparelho tem vários microfones e um
deles pode estar quebrado, quem está no cockpit precisa poder trocar sem
recompilar. Fase a definir.

### A lição de método

O piloto sugeriu pesquisar antes de tentar de novo, e estava certo: o README do
`record_android` já dizia três das coisas que as tentativas descobriram na
marra — *"there is no gain settings to play with"*, *"choosing source other than
default or mic will likely lower the output volume"*, *"applying effects will
lower the output volume"*.

E o teste que resolveu — um app isolado com só o pacote `record`, varrendo as
fontes — deveria ter vindo antes de qualquer ajuste, porque ele **particiona**
o problema: qualquer que fosse o resultado, metade das hipóteses morria. Ajuste
seguido de teste só responde sobre o ajuste.

