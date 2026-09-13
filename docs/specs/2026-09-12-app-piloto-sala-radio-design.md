# Design: App de comunicação entre pilotos (sala + ponte de rádio VHF)

Continuação de [2026-08-11-smartphone-vhf-radio-bridge.md](2026-08-11-smartphone-vhf-radio-bridge.md), que cobre o hardware da ponte ESP32↔Baofeng (Marcos 1–3 concluídos). Este documento define o sistema de comunicação em grupo construído sobre aquela ponte, e **substitui as seções 5 e 6 da spec anterior** (que assumiam Kotlin nativo + Bluetooth Classic/SPP).

> **Revisado em parte.** As seções 5.3 (fila de reprodução) e 6.3 (buffer de TTL) foram revisadas por [2026-09-13-fase-2-sala-e-backend-design.md](2026-09-13-fase-2-sala-e-backend-design.md), que introduz prazo de validade para o áudio.

## 1. Problema

Pilotos em voo se comunicam hoje por rádio VHF. Os smartphones seriam melhores (qualidade, histórico, identificação de quem falou), mas nos locais de voo raramente há cobertura de dados ou voz.

A ideia é usar os dois caminhos ao mesmo tempo: a rede de dados quando existe, o rádio VHF como rede secundária que funciona sem infraestrutura. Cada mensagem tenta os dois caminhos, e quem recebe fica com a primeira cópia que chegar.

### 1.1 Três tipos de participante

O sistema precisa conviver com participantes heterogêneos, e isso define quase toda a arquitetura:

| Tipo | Está na sala? | Ouve o ar? | Papel |
|---|---|---|---|
| Celular + ESP32 | sim | sim | candidato a **ponte** |
| Só celular | sim | não | depende da ponte ativa |
| Só rádio | **não** | sim | voz anônima; entra na sala através da ponte |

Quem tem só rádio não é membro da sala e não tem como ser identificado. A fala dele entra no histórico como origem `radio`, sem nome. No ar, os pilotos se reconhecem pela voz — o sistema não tenta resolver isso.

---

## 2. Arquitetura

```
                      ┌─── HTTP (áudio) ────┐
[App piloto A]────────┤                     ├──── [Laravel + Reverb]
[App piloto B]────────┤                     │      presença, eventos,
[App piloto C]────────┴─ WebSocket (eventos)┘      buffer de TTL curto
      │
      └── BLE ── [ESP32 ponte] ── cabo ── [Rádio VHF] ))) ar (((  ← pilotos só com rádio
```

Decisões estruturais, com o raciocínio que levou a cada uma:

**Sala em servidor central, não P2P.** O papel de "rede sem infraestrutura" já é do rádio VHF. Wi-Fi Direct ou BLE mesh entre celulares alcançam dezenas a poucas centenas de metros, e em voo os pilotos se dispersam por quilômetros — seria muito trabalho para um transporte que quase nunca estaria conectado, resolvendo mal um problema que o rádio já resolve bem. A rede de dados precisa ser boa no que ela é boa: qualidade, histórico e sincronização quando há cobertura.

**Uma ponte ativa por vez, eleita pelo servidor.** Se várias pontes retransmitissem, uma mensagem da sala seria transmitida no ar por várias rádios simultaneamente (colisão de RF) e uma fala do ar seria injetada várias vezes na sala. O servidor escolhe o primeiro candidato disponível e promove o próximo quando ele cai. Árbitro central elimina split-brain — dois celulares nunca se consideram ponte ao mesmo tempo por discordarem entre si.

**Deduplicação por janela de tempo, não por identificação de locutor.** Com ponte única, o problema colapsa: o ESP32 desarma a detecção de recepção enquanto o próprio PTT está ligado, mais ~500 ms de guarda depois (squelch tail). Tudo que chega do ar fora dessa janela é, por definição, de quem não está na sala. Identificar quem falou a partir do áudio seria inviável; supressão de laço por janela é trivial.

**Mensagem de no máximo 5 segundos.** Áudio mais longo é quebrado em segmentos de 5 s, marcados com id de rajada + índice. A regra vale também para o áudio vindo do rádio, que não tem como ser limitado na origem: ao atingir 5 s o ESP32 fecha o segmento e abre o próximo **sem parar de capturar** — o corte é no metadado, nunca no áudio.

**Dois níveis de qualidade de áudio.** Consequência física, não escolha: o caminho de dados carrega áudio comprimido a 16 kHz, e o caminho do rádio é limitado a ~3 kHz de banda pelo próprio VHF. O app grava PCM cru uma vez e deriva as duas versões.

---

## 3. Transporte celular ↔ ESP32: BLE, não SPP

A spec anterior assumia Bluetooth Classic (SPP) como premissa não examinada, e dessa premissa concluiu Kotlin nativo + iOS como reescrita futura. Revisitando: **SPP é inacessível no iOS sem certificação MFi**, e a própria seção 6.2 da spec anterior já previa que o firmware acabaria expondo um serviço GATT customizado *além* do SPP para atender iOS.

Cortando o SPP e ficando só com o GATT que seria necessário de qualquer forma, o iOS deixa de ser reescrita e o Flutter volta a ser opção legítima — um app para os dois sistemas. Nada do firmware já pronto se perde: **nenhuma linha de Bluetooth foi escrita até agora** (Marcos 1–3 são PTT, áudio de saída e detecção/gravação, todos locais).

Alternativa considerada e descartada: perfis padrão HFP/A2DP (o ESP32 se apresentando como fone Bluetooth comum). Daria áudio bidirecional sem codec próprio e funcionaria no iOS, mas exigiria um canal BLE em paralelo para controle de qualquer forma, o stack Classic+BLE junto é pesado de RAM no ESP32, e roteamento de áudio para um dispositivo específico no iOS é território problemático do `AVAudioSession`. E o ganho que justificaria esse custo não existe: o app retém a gravação completa de qualquer forma (para comprimir, subir ao servidor e guardar no histórico), então um perfil de áudio bidirecional em tempo real não elimina nenhum buffer — só troca um protocolo simples de pedaços por um stack de Bluetooth muito maior.

Vazão prática do ESP32 em BLE: 5–20 KB/s de payload útil. ADPCM a 8 kHz consome ~4 KB/s — mais rápido que tempo real, com margem, mas **sem garantia**: BLE engasga (o rádio do celular divide antena com Wi-Fi, o Android reagenda intervalos de conexão por conta própria). Daí a política de underrun em 4.2.

---

## 4. Firmware ESP32

### 4.1 Serviço BLE GATT

| Characteristic | Direção | Conteúdo |
|---|---|---|
| `tx_audio` | app → ESP32 (write without response) | pedaços de ADPCM 8 kHz, com cabeçalho de id de rajada + índice + sequência |
| `rx_audio` | ESP32 → app (notify) | pedaços do áudio capturado do ar, mesmo formato |
| `state` | ESP32 → app (notify) | ocioso / recebendo / transmitindo / canal ocupado / underrun / erro |

**Não existe comando de PTT.** O app nunca aciona o rádio; ele entrega áudio e o ESP32 decide quando ir ao ar. Isso não é só simplificação: mantém o *timing* crítico fora do BLE. Se o app tivesse que mandar "liga PTT" e depois o áudio, qualquer engasgo do Bluetooth viraria um buraco no ar ou um PTT preso.

### 4.2 Máquina de estados

```
OCIOSO ──chegou áudio do app──→ AGUARDANDO BUFFER (acumula ~2 s)
   │                                      │
   │                          canal livre por 500 ms + backoff aleatório
   │                                      ↓
   │                              TRANSMITINDO (PTT on, +150 ms, toca)
   │                                      │
   │                          fim da rajada, ou underrun > 400 ms
   │                                      ↓
   │                              GUARDA (500 ms, detecção desarmada)
   │                                      ↓
   └──energia sustentada 150 ms──→ RECEBENDO (com pré-roll de 300 ms)
                                          │
                              700 ms de silêncio, ou 5 s de segmento
                                          ↓
                                  OCIOSO (ou próximo segmento)
```

Quatro comportamentos carregam o projeto:

**Pré-roll de 300 ms.** Buffer circular sempre girando. A detecção por energia precisa de ~150 ms de energia sustentada para confirmar que é fala e não estalo — mas quando confirma, esses 150 ms já passaram. Sem o pré-roll, toda mensagem recebida perde a primeira sílaba.

**Canal livre antes do PTT.** Reusa a medida de energia do ADC já implementada no Marco 3 — é o mesmo sinal. O canal precisa estar em silêncio por ~500 ms, mais um backoff aleatório curto: se duas pontes tentarem ao mesmo tempo (situação que a eleição deveria impedir, mas que pode ocorrer em falha), o jitter faz uma ganhar em vez de as duas colidirem. Canal ocupado → a mensagem espera na fila de transmissão.

**Underrun.** Com o PTT ligado e o buffer vazio, o rádio fica no ar transmitindo silêncio. Tolera-se até 400 ms esperando dados; passando disso, solta o PTT e reporta pelo `state`. O app marca a mensagem como transmitida parcialmente. Melhor uma frase cortada com aviso do que o canal travado.

**PTT contínuo entre segmentos da mesma rajada.** Se cada segmento de 5 s virasse um acionamento de PTT separado, uma fala de 12 s sairia no ar picotada em três, com buracos entre elas e risco de outro rádio entrar no meio. A ponte segura o PTT enquanto houver segmentos consecutivos da mesma rajada: a sala vê 3 mensagens de 5 s, o ar ouve uma transmissão contínua. A quebra é do modelo de dados, não do rádio.

### 4.3 Memória

ADPCM a ~4 KB/s significa ~20 KB por segmento de 5 s. Um ESP32 comum (~300 KB de RAM utilizável, descontada a pilha BLE) segura a mensagem e uma fila com folga grande. **Placa com PSRAM (ESP32-WROVER) não é necessária** no desenho atual — fica como opção, se a fila de transmissão precisar crescer. Decidir medindo, na Fase 1; a troca é transparente para o código.

### 4.4 Reaproveitamento

Os Marcos 1–3 já validados viram diretamente blocos desta máquina de estados: PTT isolado por PC817, saída de áudio via transformador 1:1, detecção de energia com estimativa adaptativa de DC e taxa de amostragem efetiva medida. Código novo: BLE/GATT, as filas, o pré-roll, ADPCM, controle de underrun e segmentação de 5 s.

---

## 5. App Flutter

### 5.1 Módulos

```
lib/
├── ble/        → conexão com o ESP32, GATT, remontagem de pedaços
├── audio/      → captura PCM em stream, codecs, player de fila
├── room/       → cliente Reverb (presença, eventos), upload/download HTTP
├── bridge/     → candidatura e heartbeat de ponte, fila de transmissão
├── history/    → SQLite local + arquivos de áudio no dispositivo
├── background/ → foreground service (Android) / sessão de áudio (iOS)
└── ui/         → sala, histórico, botão de PTT, status de conexão
```

### 5.2 Pipeline de gravação — grava uma vez, deriva duas

O microfone entrega PCM cru em stream. Em tempo real, cada pedaço é convertido para 8 kHz/ADPCM e empurrado ao ESP32 por BLE — é isso que permite a transmissão começar antes de o piloto terminar de falar. Em paralelo, o PCM completo se acumula e, ao soltar o PTT, é comprimido e enviado ao servidor.

No sentido inverso, a ponte baixa uma mensagem da sala, decodifica, reamostra para 8 kHz, converte para ADPCM e transmite ao ESP32 em pedaços.

### 5.3 Fila de reprodução — FIFO estrito

O app se comporta como um rádio: **uma voz por vez, nunca sobreposta**. Entram na mesma fila o áudio ao vivo do rádio, os segmentos gravados do rádio e as notas da sala, em ordem de chegada. Enquanto o piloto está com o PTT acionado, nada toca — a fila acumula e volta quando ele solta (meio-duplex).

Consequência aceita conscientemente: quando houver algo tocando, o áudio ao vivo do rádio entra atrás e o atraso é o tempo restante do que está tocando. Como o teto de mensagem é 5 s, **o atraso máximo introduzido pela fila é 5 s** — limitado e previsível, que é o ponto do FIFO. Na maior parte do tempo a fila está vazia e o rádio toca ao vivo.

Alternativa considerada e descartada: prioridade para o ao vivo, interrompendo e retomando o que está tocando. Mais fiel a um rádio, mas com dois comportamentos diferentes na mesma tela e risco de o piloto se perder no que está ouvindo.

### 5.4 Recepção ao vivo

O ESP32 envia pedaços do áudio recebido enquanto ainda captura; o app toca com ~0,5–1 s de atraso e, em paralelo, acumula o segmento completo para o histórico e para a sala. Isso preserva o comportamento de rádio que os pilotos já conhecem: "tem tráfego no seu três horas" precisa chegar na hora, não 15 segundos depois.

Faseamento: **em blocos primeiro, ao vivo depois** — o caminho completo (gravar → BLE → PTT → ar → outro rádio → ADC → BLE → app) precisa funcionar ponta a ponta antes de valer a pena otimizar latência. Concretamente: a recepção em blocos completos entra no início da Fase 1, e o streaming ao vivo da recepção entra no fim da mesma fase, depois do ciclo fechado. A transmissão (5.2) já nasce em pedaços desde o início, porque a marca d'água e o controle de underrun são parte da máquina de estados do firmware, não uma otimização posterior.

### 5.5 Funcionamento em segundo plano — requisito, não desejável

O piloto pode ficar só na escuta, com o celular no bolso e a tela apagada, ou transmitir por um botão externo nessa condição. Isso precisa funcionar.

**Android** — Foreground Service com os três tipos declarados: `connectedDevice` (BLE), `microphone` (gravação) e `mediaPlayback` (reprodução).

> Armadilha que decide o desenho da tela inicial: desde o Android 12, um serviço com tipo `microphone` só pode ser iniciado com o app visível. Se o serviço não estiver de pé, um PTT acionado com a tela apagada é bloqueado ao tentar acessar o microfone. O app precisa de uma ação explícita de **"entrar em voo"**, feita com o app aberto, que sobe o serviço para o voo inteiro.

Além disso: isenção de otimização de bateria (Doze derruba conexões), wake lock parcial, e documentação de whitelist de autostart para Xiaomi/Samsung/Huawei, que matam apps em background por conta própria. Permissões: `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` (com `neverForLocation`), `RECORD_AUDIO`, `POST_NOTIFICATIONS`, mais os `FOREGROUND_SERVICE_*` correspondentes.

**iOS** — `UIBackgroundModes: audio + bluetooth-central`, com uma `AVAudioSession` em `playAndRecord` mantida ativa. Enquanto ela vive, o processo vive: o BLE continua, o WebSocket continua, e gravar em background é permitido.

Ressalvas honestas: a App Store examina com rigor apps que gravam em background (precisa de justificativa clara na submissão); e se o sistema suspender o app mesmo assim, a reconexão busca o que perdeu por HTTP — é exatamente para isso que o buffer de TTL no servidor existe (7.3).

O caminho oficialmente sancionado para este tipo de app é o framework **PushToTalk** (iOS 16+), que dá UI de sistema e privilégios de áudio adequados, ao custo de entitlement específico (`com.apple.developer.push-to-talk`), conta paga de desenvolvedor e push via APNs. Fica como evolução (Fase 5), não requisito inicial.

### 5.6 Acionamento do PTT — possibilidades documentadas, decisão adiada

Decisão adiada de propósito: isso só entra depois de o app estar funcionando. O levantamento fica registrado porque afeta que hardware comprar.

| Opção | Android, tela apagada | iOS, tela apagada | Custo |
|---|---|---|---|
| Botão na tela | n/a | n/a | nenhum — precisa existir de qualquer forma (é o único caminho de quem só tem celular) |
| Botão com fio no ESP32 | funciona | funciona | um GPIO com pull-up; comportamento idêntico nos dois sistemas; operável com luva |
| Fone Bluetooth (botão ou gesto) | via `MediaSession` | via `MPRemoteCommandCenter` | hardware que todos já têm; depende do fone emitir play/pause |
| Botão BLE de prateleira (anel, guidão, "AB Shutter") | só se emitir tecla de mídia | só se emitir tecla de mídia | varia por modelo — exige homologar quais funcionam |

As duas últimas usam o mesmo mecanismo: comando de mídia capturado pela sessão de áudio ativa. **Botões que emitem volume ou disparo de foto não funcionam em segundo plano** em nenhuma das duas plataformas. Fones Bluetooth com botão mapeável são provavelmente a opção mais prática, por ser hardware que os pilotos já carregam.

### 5.7 Pacotes

`flutter_blue_plus` (BLE), `record` (captura PCM em stream), `audio_service` (sessão de áudio e comandos de mídia nos dois sistemas — o mesmo mecanismo do PTT sem fio), `flutter_foreground_task` (serviço Android), `pusher_channels_flutter` (cliente oficial Pusher, compatível com Reverb — os ports Dart do Laravel Echo são menos confiáveis), `dio` (HTTP com retomada), `drift` (SQLite local), `permission_handler`.

ADPCM é simples o bastante para implementar direto em Dart, sem dependência externa.

---

## 6. Backend Laravel

### 6.1 Escolha da stack

**Laravel + Reverb, containerizado com FrankenPHP/Octane.**

O backend é a peça mais simples do sistema: fanout de eventos para salas de 3–15 pessoas, blobs de ~20 KB com TTL, presença e auth mínima. Qualquer stack moderna resolveria isso em um fim de semana. O critério decisivo foi outro: a dificuldade real do projeto está no firmware, no BLE e nas restrições de segundo plano do iOS. Gastar orçamento cognitivo aprendendo backend novo enquanto se depura underrun de BLE é trocar esforço de onde ele é barato por onde ele é caro. Laravel é o ambiente de trabalho diário do desenvolvedor.

Duas observações que de-riskificam a escolha:

- **Reverb não é uma decisão travada.** Broadcasting no Laravel é driver: trocar Reverb por Pusher/Ably gerenciado é uma linha de config, sem tocar no código da aplicação. Começa-se com Reverb (padrão, roda local sem conta em lugar nenhum) sabendo que a saída existe se manter o daemon de pé incomodar.
- **FrankenPHP responde a crítica de containerização.** Laravel clássico é nginx + PHP-FPM + worker + Reverb + scheduler; com FrankenPHP (padrão do Octane hoje) fica um binário único servindo HTTP, com worker mode embutido, mais o Reverb como segundo processo.

Sobre o argumento de assincronia a favor de Node/TypeScript: ele vale quando o processo da aplicação segura muitas conexões longas. Aqui as conexões longas **não vivem no Laravel** — vivem no Reverb, que por baixo é ReactPHP, ou seja, um event loop. Ao Laravel sobram requisições curtas e dois jobs de fundo. O ponto onde Node/Go passariam na frente seria **processar mídia no servidor** (transcodificar, mixar, servir streams contínuos); neste desenho o servidor nunca toca no áudio, só encaminha bytes opacos.

Alternativas avaliadas: Supabase (quase nenhum backend a escrever, mas lock-in e menos controle sobre a lógica de eleição), Firebase (o `onDisconnect` do Realtime Database é literalmente o primitivo da falha de ponte, sem heartbeat, mas lock-in pesado), MQTT (Last Will and Testament é feito exatamente para "esse cliente morreu"; interessante se um dia houver ESP32 falando Wi-Fi direto, mas é mais uma peça de infra e ainda exige storage à parte), Phoenix/Elixir (melhor encaixe técnico, não justifica adotar uma linguagem nova pela parte mais fácil do projeto).

### 6.2 Papel do servidor: roteador e árbitro, nunca arquivo

**Endpoints HTTP**

- `POST /messages` — sobe o áudio de um segmento (≤5 s) com id de rajada, índice, duração e origem. Grava no storage temporário, dispara o evento, responde.
- `GET /messages/{id}/audio` — baixa o áudio. Suporta Range (retomável), para sobreviver a sinal ruim.
- `GET /rooms/{id}/pending` — backlog de quem esteve offline, dentro do TTL.

**Eventos no Reverb** (presence channel por sala)

- `message.new` — metadados apenas: id, autor, duração, id de rajada, índice, origem (`app` ou `radio`)
- `bridge.changed` — quem é a ponte ativa agora
- presença nativa do canal — entrada e saída de membros, sem código adicional

Reverb carrega **apenas eventos, nunca áudio**. O protocolo é o do Pusher: frames de texto JSON com limite na casa de 10 KB por mensagem. Áudio exigiria base64 (infla 33%) fatiado em dezenas de eventos, reimplementando fatiamento, remontagem e retomada sobre um canal que não foi feito para isso. HTTP é retomável, resiliente a queda de sinal e trivial de depurar — o que importa muito numa rede ruim, que é a condição normal de operação.

### 6.3 Buffer de TTL curto — por que o servidor precisa guardar algo

Broadcast de WebSocket entrega apenas a quem está conectado naquele instante. O piloto que estava sem sinal e recupera cobertura cinco minutos depois não receberia nada — e ficar sem cobertura no meio do voo é a premissa do projeto, não a exceção.

Por isso o servidor guarda o áudio **temporariamente, como fila de saída**: TTL de 30–60 min, apagado por job agendado. Não é histórico. **O histórico permanente é 100% do dispositivo**; quem não estava na sala naquele voo nunca vê aquelas mensagens, e isso é intencional.

### 6.4 Eleição de ponte

Estado efêmero em Redis. Ao entrar na sala, cada membro anuncia sua capacidade (`tem ESP32 conectado: sim/não`). O servidor elege o **primeiro candidato disponível** e publica `bridge.changed`. A ponte manda heartbeat a cada ~10 s; sem heartbeat por ~30 s, ou ao sair do presence channel, o servidor promove o próximo candidato e publica de novo.

### 6.5 Autenticação

Conta mínima (Sanctum), o suficiente para identificar quem falou no histórico e dar identidade estável à eleição de ponte. Sala permanente por grupo, entrada por convite. Modelo WhatsApp.

Alternativas descartadas: sala efêmera por voo (simples, mas cada voo começa do zero), sala pública por frequência de rádio (qualquer um entra na conversa), identidade só por dispositivo sem conta (trocou de celular, perdeu tudo, e a eleição fica sem identidade estável).

---

## 7. Faseamento

Cada fase tem spec e plano próprios, e entrega algo testável sozinho.

### Fase 0 — Marco 4 do firmware *(já previsto na spec anterior)*
Ciclo completo sem app: transmite áudio da flash, grava a resposta, reproduz. Fecha a validação do hardware antes de qualquer Bluetooth entrar em cena.

### Fase 1 — Ponte BLE + app mínimo *(primeira spec nova a escrever)*
Serviço GATT no ESP32, máquina de estados com PTT autônomo, canal livre, pré-roll, underrun, segmentos de 5 s. App Flutter com botão de gravar, botão de tocar e status de conexão. A recepção começa em blocos completos e passa a ao vivo no fim da fase (5.4). **Sem sala, sem servidor, sem histórico.** Entrega um walkie-talkie de um piloto só: fala no celular, sai no rádio; o rádio recebe, toca no celular.

Valida todo o caminho físico e concentra a maior incerteza técnica do projeto.

### Fase 2 — Sala e backend
Laravel + Reverb + auth + upload/download + TTL. App com sala, presença, histórico local em SQLite, fila FIFO de reprodução. **Sem ponte** — só a rede de dados. Roda em terra, sem rádio nenhum, e já é útil sozinha.

### Fase 3 — Integração: a ponte
Junta 1 e 2. Eleição pelo servidor, heartbeat, failover, relay bidirecional, supressão de eco, fila de transmissão, PTT contínuo entre segmentos da mesma rajada. É aqui que o sistema vira o que foi descrito na seção 1.

### Fase 4 — Segundo plano para valer
Foreground service com os três tipos no Android, sessão de áudio no iOS, isenção de bateria, push para reconexão, sobrevivência a fabricantes agressivos. Separada de propósito: é trabalho de plataforma, não de produto, e tem seu próprio ciclo de teste (deixar o celular no bolso por uma hora e ver o que morreu).

### Fase 5 — PTT externo e polimento de iOS
Botão no ESP32, botões de mídia e fones Bluetooth, homologação de modelos, avaliação do framework PushToTalk.

---

## 8. Riscos

Concentrados na Fase 1, e é por isso que ela vem primeiro:

- **Vazão real do BLE** no ESP32 com áudio contínuo — a margem de 4 KB/s contra 5–20 KB/s existe no papel, falta medir
- **Marca d'água do buffer de transmissão** — qual valor evita underrun sem atrasar demais; 2 s é chute conservador a calibrar
- **Detecção de canal livre com o squelch do Baofeng** no mundo real, não em bancada
- **Inteligibilidade de 8 kHz/ADPCM** depois da ida e volta pelo rádio VHF

Fora da Fase 1:

- **Restrições de segundo plano do iOS** — o maior risco de plataforma; pode forçar o framework PushToTalk (e a conta paga) antes do previsto
- **Fabricantes Android agressivos** matando o foreground service

---

## 9. Questões em aberto

A resolver quando a fase correspondente chegar, não agora:

- Formato exato do cabeçalho dos pedaços BLE (id de rajada, índice, sequência, checksum)
- Codec do caminho de dados: AAC nativo (mais simples, suportado pelos dois sistemas) vs Opus (melhor em baixa taxa, exige biblioteca nativa no Flutter)
- Esquema do SQLite local do histórico
- Necessidade de PSRAM na placa — decidir medindo, na Fase 1
- Política de retentativa quando a ponte cai no meio de uma fila de transmissão
- Design de UI da sala e do histórico
