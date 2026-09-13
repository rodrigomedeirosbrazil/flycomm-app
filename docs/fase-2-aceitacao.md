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

## 7.1 Escuta em segundo plano no iOS — conexão verificada, áudio pendente

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
