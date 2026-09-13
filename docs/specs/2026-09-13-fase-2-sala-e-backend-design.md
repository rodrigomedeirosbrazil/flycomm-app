# Design: Fase 2 — Sala e backend, sem rádio

Detalhamento da Fase 2 descrita em [2026-09-12-app-piloto-sala-radio-design.md](2026-09-12-app-piloto-sala-radio-design.md).

Este documento **revisa as seções 5.3 e 6.3 da spec anterior**. O motivo está na seção 2: áudio de comunicação em voo tem prazo de validade, e a spec anterior desenhou um buffer de servidor (TTL de 30–60 min) e uma fila de reprodução que não levavam isso em conta.

## 1. Escopo

A sala e o backend rodando em terra, sem rádio e sem ESP32. Dois ou mais celulares na mesma sala: um piloto segura o PTT e fala, os outros ouvem. O histórico fica no dispositivo.

Fora do escopo, cada um na sua fase: BLE e firmware (Fase 1), ponte e eleição (Fase 3), segundo plano (Fase 4), PTT externo (Fase 5).

A Fase 2 é útil sozinha — um walkie-talkie de grupo sobre rede de dados — e é isso que a torna testável antes de existir qualquer rádio.

---

## 2. Áudio tem prazo de validade

A decisão que organiza todo o resto.

Uma fala que chega três minutos depois não é informação, é ruído: o piloto já passou do ponto sobre o qual estavam falando. "Tem tráfego no seu três horas" entregue com atraso é pior que silêncio, porque desloca a atenção para algo que não existe mais.

Disso saem os orçamentos de tempo do sistema:

| Config | Padrão | Significado |
|---|---|---|
| `playback_deadline_ms` | 30 s | idade máxima para o app tocar sozinho |
| `radio_relay_deadline_ms` | 10 s | idade máxima para ir ao ar (usado na Fase 3, definido aqui) |
| `delivery_deadline_ms` | 5 min | até quando o app insiste em subir antes de desistir de vez |
| `segment_max_ms` | 5 s | teto do segmento |
| `catchup_window_ms` | 60 s | quanto o catch-up de reconexão olha para trás |
| `blob_ttl_ms` | 5 min | vida do áudio no storage |

**Todos configuráveis no servidor**, entregues ao app no login e na entrada da sala. Os valores são chutes a calibrar em campo, e calibrar não pode depender de publicar versão nova na loja.

Os nomes carregam a unidade porque os valores trafegam em milissegundos inteiros — `playback_deadline_ms: 30000` —, do mesmo jeito que o `duration_ms` da mensagem. A tabela acima mostra o padrão em segundos só por legibilidade.

**A idade é medida contra o relógio do servidor**, nunca contra o do celular cru. Relógios de celular derivam; um device adiantado descartaria mensagens boas e um atrasado tocaria mensagens vencidas. O app calcula o desvio a partir da resposta HTTP e aplica na comparação.

A seção 2.1 qualifica isto e a qualificação é importante: a idade *da fala* passa a sair de `captured_at`, um carimbo do cliente — feito com esse mesmo relógio já corrigido, obrigatório e validado, mas do cliente. É uma concessão deliberada, com mitigações, e está descrita lá.

Para o app não depender só do header `Date`, `GET /config` e `GET /rooms/{id}/catchup` devolvem um campo `server_time` explícito, em ISO 8601 com microssegundos e sufixo `Z`. É esse o relógio contra o qual toda idade é medida.

### 2.1 O que isso muda na spec anterior

**O buffer de TTL curto (6.3) encolhe de 30–60 min para minutos.** Ele existia para o piloto que recupera cobertura cinco minutos depois receber o que perdeu. Com prazo de 30 s, esse áudio não deveria tocar de jeito nenhum — baixar cinco minutos de gravação para não reproduzir nenhuma é trabalho puro. O storage passa a cobrir engasgo de reconexão, não ausência.

**O `pending` muda de natureza e vira `catchup`.** Deixa de ser "backlog de quem esteve offline" e passa a ser "o que foi publicado nos últimos 60 s que eu não vi". Cobre o caso real e frequente — o WebSocket cai e reconecta oito segundos depois — e deliberadamente não cobre ausência longa, que por definição não precisa ser coberta.

A janela do catch-up (60 s) é maior que o prazo de reprodução (30 s) de propósito: o excedente não toca, mas preenche o histórico local do que passou enquanto o app estava desconectado. Sem isso haveria um buraco no histórico sem nenhum indício de que algo aconteceu ali.

**A fila FIFO (5.3) ganha regra de descarte.** Se a fila tem oito mensagens, a cauda já venceu antes de chegar a vez. Item cuja idade passa do `playback_deadline` sai da fila sem tocar e é marcado no histórico como atrasado — ouvível por toque, nunca automaticamente. O teto de atraso da fila deixa de ser "5 s por item acumulado" e passa a ser o próprio prazo, que é mais honesto.

**A mensagem sobe mesmo depois de vencida — e não toca em ninguém.**

A versão anterior desta seção decidia o contrário: não existia fila de saída, o upload tentava durante a janela de validade e desistia, e a mensagem ficava só no histórico local como não entregue. O argumento era que guardar uma mensagem para subir "quando der" só faz sentido se alguém fosse ouvi-la, e não vai.

O argumento confundiu **não tocar** com **não enviar**. Áudio atrasado é inútil como comunicação ao vivo — isso continua verdade e continua sendo a regra que organiza tudo. Mas o histórico da sala não é comunicação ao vivo, e para ele áudio atrasado não é ruído, é registro. Do jeito anterior, A ficar sem rede significava que B nunca ficava sabendo que A tinha falado, e o buraco no histórico de B era invisível para B — o mesmo defeito que a janela de catch-up de 60 s existe para corrigir, com o agravante de não deixar nem indício.

Então o upload insiste até `delivery_deadline_ms`, contado a partir da captura. Quando completa, a mensagem entra na sala de todo mundo. Ela **não toca automaticamente em ninguém**: chega vencida, e item vencido não toca, sem exceção. Aparece marcada como **atrasada**, ouvível por toque, e é encaixada na linha do tempo na posição em que foi **gravada**, não em que chegou — uma fala das 12:00:00 que só subiu às 12:03:00 pertence às 12:00:00, e jogá-la no fim da lista contaria uma história errada sobre a ordem em que as coisas foram ditas.

Passado o `delivery_deadline`, o app desiste de vez e a mensagem fica como **não entregue**, com o piloto avisado — que é a informação de que ele realmente precisa: ninguém te ouviu, use o rádio. O teto não é decoração: sem ele o app tentaria para sempre, e a fila de saída persistente que esta spec recusou por bons motivos voltaria pela porta dos fundos, com o agravante de ser invisível, porque ninguém teria decidido criá-la.

**A concessão: o frescor da fala passa a sair do relógio do cliente.**

Isto custa uma coisa, e a coisa precisa estar escrita aqui em vez de acontecer por acidente.

Com entrega atrasada permitida, `created_at` deixa de servir como medida de frescor. Ele é o instante em que o servidor recebeu, e o servidor agora pode receber minutos depois de a fala ter acontecido: uma mensagem gravada em T e subida em T+3min tem `created_at` recente e pareceria fresca, quando a fala tem três minutos. Decidir "toca ou não toca" por ele faria exatamente o que a seção 2 existe para impedir.

A idade **da fala** passa então a ser medida por `captured_at`, que é o relógio do cliente — precisamente aquilo de que esta seção desconfia. Quatro coisas limitam o estrago:

- **O carimbo não é o relógio local cru.** O cliente corrige o desvio contra o `server_time` e carimba `captured_at` com o relógio do servidor já corrigido. O erro que sobra é o da estimativa de desvio — a casa do round-trip de uma requisição —, não o da deriva do aparelho.
- **`captured_at` passa a ser obrigatório quando `origin` é `app`** (6.2.1). Opcional, ele seria nulo justamente nos clientes que não implementaram a correção de desvio, que são os que mais precisam dela.
- **O servidor recusa valor impossível** (6.2.1): à frente do próprio relógio, ou velho demais para ter sido gravado dentro da janela de entrega. Um aparelho adiantado não consegue fazer uma fala nunca envelhecer; um atrasado não consegue fazer toda fala nascer vencida.
- **`created_at` continua sendo a autoridade de ordenação no transporte e do catch-up.** O `since`, a janela de 60 s e a ordem em que o servidor devolve mensagens continuam saindo de carimbo do servidor, imunes ao cliente. O que mudou de mão foi uma pergunta só: quantos segundos tem esta fala.

A divisão que fica: **`created_at` responde "quando isto chegou", `captured_at` responde "quando isto foi dito"**. A primeira é do servidor e ordena o transporte; a segunda é do cliente, é obrigatória, é validada, e é a única que decide se o áudio toca.

**Fresco na frente.** Se há mensagem atrasada esperando para subir e o piloto fala de novo, o segmento novo passa na frente: ele ainda pode ser ouvido ao vivo, e o atrasado, por definição, não pode. A subida do atrasado é trabalho de fundo — cede a rede para o que ainda tem prazo e só volta quando não há nada fresco esperando. Sem essa ordem, uma perda de cobertura seguida de fala nova faria o registro do passado atrasar a conversa do presente, que é o pior dos dois mundos.

**Sem internet, a sala vira log local.** Não há sala, não há membros, não há eventos: o rádio é a rede. O app continua registrando no histórico do dispositivo o que aquele aparelho transmitiu e (na Fase 3) o que o rádio captou. Quando a internet volta, nada sobe retroativamente.

---

## 3. Sala

Nome, frequência e um código de convite. Nada mais.

**A frequência é informativa.** O ESP32 não sintoniza o Baofeng — não há controle CAT no desenho — então quem muda a frequência é o piloto, na mão, no rádio. O campo declara "estamos no 145.550"; o sistema nunca verifica se algum rádio está mesmo ali. Guardada como **inteiro em Hz** (`145550000`), para não carregar erro de ponto flutuante numa comparação. Validada nas faixas do rádio (136–174 MHz e 400–470 MHz), faixas também configuráveis.

**É opcional.** Na Fase 2 não existe rádio, e toda sala de teste nasceria com um número inventado. Nullable também descreve com honestidade o estado "ainda não combinamos a frequência", que continua real depois da Fase 3.

**A sala é plana.** Qualquer membro renomeia, muda a frequência e passa o código adiante. O grupo é de 3–15 pilotos que voam juntos; o custo de alguém mudar a frequência errado é um aviso no grupo, não um incidente. E a frequência muda *porque* o grupo combinou mudar — travar isso no dono só cria fricção quando ele não está por perto.

Mas o vínculo membro↔sala já nasce com coluna `role`, todos `member`, ninguém checando nada. O modelo de papéis (dono + admins + membros) vai chegar; quando chegar, é escrever policies, não migrar dados.

**Entrada por código curto** (`FLY-7K2M`). É a menor superfície que já é testável de verdade: dois celulares, um código digitado, sala compartilhada. Deep link (`flycomm://join/...`) é literalmente isto embrulhado, e entra quando o app estiver de pé. Convite nominal exigiria modelo de convites pendentes e busca de usuários — uma decisão de privacidade que não precisa ser tomada agora.

O corpo do código são 4 caracteres do alfabeto `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` — sem `0`/`O` nem `1`/`I`, porque o código é ditado em voz alta, às vezes pelo próprio rádio. O servidor normaliza o que o piloto digita: aceita minúscula, com ou sem hífen, com ou sem o prefixo `FLY`.

---

## 4. Identidade

**A identidade é o `user`; credencial é um anexo.** Essa separação é a única parte do desenho de auth que importa de verdade.

Hoje a credencial é do tipo `device`: no primeiro uso o app gera um segredo, guarda no armazenamento seguro da plataforma e o troca por um token Sanctum de vida longa. O piloto escolhe um nome de exibição e pronto — nenhum serviço externo, nada a digitar, `docker compose up` e funciona.

A dívida é conhecida e aceita: trocou de celular, perdeu tudo. Ela existe porque reivindicar a conta depois — e-mail e senha, ou login social — é inserir uma linha em `credentials` apontando para o mesmo `user_id`, sem perder salas nem histórico. Se `email` e `password` morassem em `users`, essa evolução seria uma migração e uma reescrita de sessão.

---

## 5. Mensagens e segmentação

**Segmentar em 5 s desde já, mesmo sem rádio.** Uma fala de 12 s vira três mensagens com `burst_id` e `index`.

O teto de 5 s nasceu do rádio — underrun, canal ocupado, PTT contínuo entre segmentos — e na Fase 2, sozinha, parece burocracia sem motivo: você corta áudio por uma razão que ainda não existe na tela. Vale mesmo assim porque rajada e índice não são detalhe de transporte. Eles atravessam o schema do servidor, o SQLite local, a fila de reprodução e o modo como a UI agrupa uma fala. Introduzir isso na Fase 3 significaria mexer nas quatro camadas ao mesmo tempo, justamente na fase em que a eleição de ponte e a supressão de eco estão sendo depuradas. Agora custa um contador e dois campos.

**O corte é no metadado, nunca no áudio:** ao atingir 5 s o app fecha o segmento e abre o próximo sem parar de capturar.

### 5.1 Formato

**PCM 16 bits a 16 kHz, embrulhado em WAV, sem compressão.** ~160 KB por segmento de 5 s.

A spec anterior deixou o codec em aberto (AAC nativo vs Opus) e essa escolha continua aberta — mas implementar exige gravar em *algum* formato. PCM cru mantém o pipeline no formato final da 5.2 da spec anterior ("grava PCM uma vez, deriva duas") e deixa a compressão como um encaixe único e isolado. Gravar direto em AAC seria mais simples hoje e faria a Fase 3 reescrever a camada de áudio para voltar a PCM em stream.

O servidor trata áudio como bytes opacos: a mensagem carrega um campo `format`, e trocar WAV por Opus ou AAC depois não toca no backend nem no schema. O custo aceito é tamanho — irrelevante em Wi-Fi de bancada, caro em rede real, e por isso a compressão não pode ser esquecida antes da Fase 3.

---

## 6. Backend

Laravel + Reverb, conforme a seção 6.1 da spec anterior. O servidor é roteador e árbitro, nunca arquivo.

### 6.1 Modelo de dados

**`users`** — `id`, `display_name`.

**`credentials`** — `user_id`, `type` (`device` hoje; `email`, `oauth` depois), `identifier` (único), `secret_hash`.

**`rooms`** — `id`, `name`, `frequency_hz` (inteiro, nullable), `invite_code` (único), `created_by`.

**`room_user`** — `room_id`, `user_id`, `role`, `joined_at`.

**`messages`** — `id` (uuid), `room_id`, `user_id` (nullable: origem `radio` não tem autor), `burst_id`, `index`, `duration_ms`, `origin` (`app` | `radio`), `format`, `size_bytes`, `captured_at` (do cliente; obrigatório quando `origin` é `app` — é a idade da fala, 2.1), `created_at` (do servidor: ordenação do transporte e piso do catch-up), `expires_at`.

Áudio no MinIO, nunca no banco. Um job de minuto em minuto apaga blob e linha juntos, passado o `expires_at`.

### 6.2 Endpoints

```
POST   /auth/device          cria ou recupera o usuário, devolve token Sanctum
PATCH  /me                   nome de exibição
GET    /config               os orçamentos da seção 2
POST   /rooms                cria (nome, frequência opcional)
PATCH  /rooms/{id}           renomeia / muda frequência (qualquer membro)
POST   /rooms/join           entra por código
POST   /rooms/{id}/leave
GET    /rooms                minhas salas
POST   /rooms/{id}/messages  multipart: áudio + metadados
GET    /messages/{id}/audio  com Range, retomável
GET    /rooms/{id}/catchup   o que foi publicado na janela e eu não vi
```

Sem prefixo: os caminhos são literalmente esses. Todos exigem token Sanctum, menos dois: `POST /auth/device`, que é onde o token nasce, e `GET /config`, que não carrega segredo nenhum e precisa ser legível antes do primeiro login — é dele que o app tira os orçamentos para decidir o que fazer com o que gravou offline.

### 6.2.1 O que o cliente manda

A resposta está descrita acima; a requisição também precisa estar, porque um campo obrigatório que o app descobre por um 422 é uma tarde perdida.

| Rota | Campo | Regra |
|---|---|---|
| `POST /auth/device` | `identifier` | obrigatório, 16–128 caracteres |
| | `secret` | obrigatório, 32–72 caracteres (o teto é o do bcrypt) |
| | `display_name` | opcional; obrigatório na prática só na criação, ignorado na recuperação |
| `PATCH /me` | `display_name` | obrigatório, 1–60 |
| `POST /rooms` | `name` | obrigatório, 1–80 |
| | `frequency_hz` | opcional, inteiro, dentro das faixas de `GET /config` |
| `PATCH /rooms/{id}` | `name`, `frequency_hz` | ambos opcionais; enviar `frequency_hz: null` limpa a frequência |
| `POST /rooms/join` | `invite_code` | obrigatório; aceito em minúscula, sem hífen e sem o prefixo `FLY` |
| `POST /rooms/{id}/messages` | `id` | obrigatório, uuid **gerado pelo app** |
| | `burst_id` | obrigatório, uuid |
| | `index` | obrigatório, inteiro ≥ 0 |
| | `duration_ms` | obrigatório, inteiro, teto em `segment_max_ms` |
| | `origin` | obrigatório, `app` ou `radio` |
| | `format` | obrigatório; `wav-pcm16-16k` na Fase 2 |
| | `captured_at` | ISO 8601; **obrigatório** quando `origin` é `app`, opcional quando é `radio`; recusado no futuro ou velho demais |
| | `audio` | obrigatório, arquivo, teto configurável (512 KB por padrão) |

O upload é `multipart/form-data`; o resto é JSON. `duration_ms` ter o mesmo teto que `segment_max_ms` é o que faz a regra de 5 s ser do sistema e não só do app — um cliente que ignore a segmentação é recusado pelo servidor.

**`origin` vem do cliente, e isso vira uma questão na Fase 3.** Hoje qualquer membro pode declarar `radio`, e não faz diferença: sem ponte, ninguém está injetando áudio do ar. Quando a eleição existir, só a ponte ativa deveria poder, e a autorização precisa ser revisitada junto com ela.

Cinco detalhes do contrato que não são óbvios:

**`POST /auth/device` recebe `{identifier, secret, display_name}`.** O `display_name` só é obrigatório na criação; numa recuperação ele é ignorado, porque o nome canônico vive no servidor e quem o muda é `PATCH /me`. O `secret` é guardado com bcrypt, o que impõe um teto de 72 bytes — acima disso o algoritmo trunca em silêncio e dois segredos diferentes viram o mesmo. Cada chamada emite um token novo e revoga o anterior daquele dispositivo.

**O `id` da mensagem é gerado pelo app, não pelo servidor.** É o que torna `POST /rooms/{id}/messages` idempotente: a seção 2.1 manda o upload insistir durante toda a janela de validade, e sem um id estável cada retentativa em rede ruim criaria uma mensagem duplicada na sala. Reenviar um id que já existe devolve a mensagem gravada, sem republicar o evento; reaproveitar o id de outra sala é conflito.

**`GET /rooms/{id}/catchup` aceita `?since=<ISO 8601>`.** O app manda o `created_at` da última mensagem que viu — um carimbo que o próprio servidor emitiu, nunca o relógio do celular. O piso efetivo é `max(since, agora - catchup_window)`: um `since` mais antigo que a janela é ignorado de propósito, porque ausência longa não deve ser coberta. A resposta devolve o `window_start` que realmente valeu, e é comparando-o com o `since` enviado que o app descobre que houve um buraco no histórico — sem isso, o buraco existiria sem nenhum indício.

**`captured_at` é obrigatório para `origin: app`, e validado nas duas bordas.** É por ele que o app de quem recebe decide se toca (2.1), então um valor impossível não é uma data feia no histórico: é comportamento errado na sala. O servidor recusa o carimbo que está à frente do seu próprio relógio ou mais velho que a janela de entrega — nos dois casos com uma tolerância de 5 s, que absorve o erro de estimativa de desvio e o round-trip sem deixar passar relógio errado de verdade. Os limites são `agora + tolerância` e `agora − (delivery_deadline_ms + tolerância)`, e a tolerância é config, como os orçamentos. Para `origin: radio` o campo continua opcional e ausente: não há cliente ali para carimbar, e a idade dessa fala sai do `created_at`.

**Erro de validação responde 422 com JSON, sempre.** Não há redirecionamento: a API não serve HTML, e um 302 no lugar de um 422 é um modo de falha caro de depurar em rede ruim.

### 6.3 Eventos

Presence channel `room.{id}`:

- `message.new` — só metadados, no mesmo formato que `POST /rooms/{id}/messages` e `catchup` devolvem: `id`, `room_id`, `burst_id`, `index`, `user` (objeto com `id` e `display_name`, ou `null` quando a origem é `radio`), `duration_ms`, `origin`, `format`, `size_bytes`, `captured_at`, `created_at`, `expires_at`, `audio_url`
- `room.updated` — nome e frequência; todo mundo precisa ver a frequência mudar sem recarregar
- presença nativa do canal — entrada e saída, sem código adicional

Mensagem tem um formato só, nos três lugares onde aparece. Três definições do mesmo objeto divergiriam, e divergiriam justamente no caminho em que o app precisa tratar as três como a mesma coisa: a que chegou pelo evento, a que voltou do upload e a que veio no catch-up são a mesma mensagem.

Reverb carrega apenas eventos, nunca áudio (6.2 da spec anterior). O `audio_url` é um link para `GET /messages/{id}/audio`, não o conteúdo.

### 6.4 Infraestrutura local

`docker compose` espelhando produção: FrankenPHP/Octane, Reverb, Postgres, Redis (cache, filas e sessão — e, na Fase 3, o estado da eleição de ponte) e MinIO como storage S3.

Espelhar produção custa três serviços a mais no compose e elimina a classe de surpresa que aparece só no deploy.

---

## 7. App

Módulos da Fase 2: `audio/`, `room/`, `history/`, `ui/`. Os módulos `ble/`, `bridge/` e `background/` da spec anterior ainda não existem.

**Gravação.** Segura o PTT → PCM 16 kHz em stream → a cada 5 s fecha um segmento e sobe, sem parar de capturar. Solta o PTT → fecha o último segmento. Meio-duplex: enquanto grava, nada toca.

**Reprodução.** FIFO estrito, uma voz por vez, nunca sobreposta. Item que passa do `playback_deadline` sai da fila sem tocar (seção 2.1).

**Estados da mensagem no histórico local.** Saída: `gravada → enviando → entregue`, `→ entregue atrasada` ou `→ não entregue`. Entrada: `recebida` ou `atrasada`.

`entregue atrasada` é o desfecho novo de 2.1: a mensagem entrou no histórico dos outros, mas depois do prazo, então ninguém a ouviu ao vivo. O app decide por `created_at − captured_at > playback_deadline` — se ao ser publicada a fala já estava vencida, nenhum receptor podia tê-la tocado. Para o piloto, `entregue atrasada` e `não entregue` dizem a mesma coisa sobre o presente (ninguém te ouviu, use o rádio) e coisas diferentes sobre o registro (ficou, não ficou); as duas precisam ser visíveis, e distintas de `entregue`.

**A linha do tempo é ordenada por `captured_at`**, com queda para `created_at` quando ele não existe — `origin: radio` não tem. É o que põe a mensagem atrasada na posição em que foi gravada em vez de no fim da lista.

**Histórico** em SQLite (drift) com os arquivos de áudio no dispositivo. Permanente, e 100% local: quem não estava na sala naquele voo nunca vê aquelas mensagens.

---

## 8. Critérios de conclusão

- Dois celulares na mesma sala: PTT em A, áudio toca em B, com a latência ponta a ponta medida e registrada
- Fala de 12 s vira três mensagens, tocadas em ordem, sem buraco entre elas
- B em modo avião por 20 s: ao voltar, o `catchup` entrega o que ainda está fresco e o vencido aparece no histórico sem tocar
- Wi-Fi desligado em A durante a fala e religado dentro do `delivery_deadline`: a mensagem sobe, aparece em B como **atrasada** sem tocar, encaixada na posição em que foi gravada, e em A como **entregue atrasada**
- Wi-Fi desligado em A além do `delivery_deadline`: a gravação fica como **não entregue**, e o piloto vê isso
- Mudança de frequência em A aparece em B sem recarregar

---

## 9. Repositórios

- `flycomm` — firmware ESP32 e as specs de todo o sistema
- `flycomm-server` — Laravel
- `flycomm-app` — Flutter

As três partes têm ciclos de release incompatíveis (firmware por cabo, backend por deploy, app por loja), e as specs já vivem no `flycomm` com todo o histórico de decisão do hardware. Os repos novos referenciam as specs por link.

---

## 10. Questões deixadas em aberto

- Codec do caminho de dados (continua aberta da spec anterior; o campo `format` é o que permite adiar)
- Design de UI da sala e do histórico — a detalhar no `flycomm-app`
- Schema exato do SQLite local — a detalhar no `flycomm-app`
- Verificação de e-mail e recuperação de senha, quando as credenciais de e-mail existirem
- Regeneração do código de convite
