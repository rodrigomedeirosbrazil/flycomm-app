# Design: Rádio primeiro — a sala vista de N antenas

Revisa [2026-09-12-app-piloto-sala-radio-design.md](2026-09-12-app-piloto-sala-radio-design.md) em pontos estruturais: a **seção 1.1** (tipos de participante), o segundo e o terceiro parágrafos de decisão da **seção 2** (ponte única eleita, deduplicação), a **seção 5.1** (módulo `bridge/`) e a **seção 6.4** (eleição de ponte) inteira. Acrescenta contrato à [Fase 2](2026-09-13-fase-2-sala-e-backend-design.md) e semântica à [Fase 1](2026-09-16-fase-1-ponte-ble-design.md), sem revogar nada das duas.

Convenção: a prosa é em português, como nas specs anteriores; **todo artefato de desenvolvimento é em inglês** — identificadores, constantes de protocolo, nomes de campo, mensagens de log e comentários.

---

## 1. A premissa que estava errada

A spec de 12/09 desenhou o sistema a partir desta tabela (§1.1):

| Tipo | Está na sala? | Ouve o ar? |
|---|---|---|
| Celular + ESP32 | sim | sim |
| Só celular | sim | **não** |
| Só rádio | não | sim |

O segundo participante — **piloto no ar com celular e sem rádio** — não existe. Todo piloto que voa com o grupo leva rádio; é equipamento de voo, não acessório. Quem está na sala sem rádio está **no solo**: a equipe de resgate, o motorista do retrieve, quem não voou naquele dia. Essa gente está longe demais para o VHF alcançar, e é justamente quem tem internet boa.

A tabela correta separa os dois eixos, que são independentes e mudam a cada minuto:

| | **com internet** | **sem internet** |
|---|---|---|
| **com rádio** | ouve tudo; é quem pode levar o ar até o solo | ouve o ar normalmente; a sala congela; sobe atrasado quando voltar |
| **sem rádio** | só a sala; depende de alguém subir o ar para ele | **isolado**: não ouve ninguém, ninguém o ouve |

Do erro saiu a decisão que esta spec desfaz. A ponte única existia para servir o participante que não existe: se alguém no ar dependesse inteiramente de outro para ouvir o rádio, faria sentido eleger cuidadosamente quem seria esse outro. Ninguém depende. Todo mundo no ar já ouve o ar com os próprios ouvidos.

### 1.1 O argumento que sobra, e ele é melhor

Não é "sem internet a comunicação continua" — sem internet não existe sala, e os pilotos se falavam pelo rádio de qualquer jeito, com ou sem app. O ganho real é outro:

> **O piloto sem sinal continua chegando na equipe de solo, pela antena de outro piloto.**

O piloto A está numa rampa afastada, sem dados. Ele fala. O áudio sai no ar. O piloto B, que naquele minuto tem sinal, ouve pelo rádio dele e sobe para a sala. A equipe de resgate, a 40 km, ouve o A — que não tem conexão com coisa nenhuma.

Com ponte única, isso só funciona se a ponte eleita por acaso ouvir o A. Cobertura de RF é por receptor, não global: relevo, altura e distância fazem cada antena ouvir um subconjunto diferente do ar. Com N receptores, a sala enxerga a **união** das antenas, e a instabilidade de sinal deixa de ser ponto de falha e vira vantagem estatística — a chance de *todos* estarem sem sinal ao mesmo tempo é muito menor que a de *um* estar.

### 1.2 O buraco que não tem conserto, e por isso precisa aparecer

Fala de quem está **sem rádio conectado** não alcança quem está **sem internet**. Ela existe só na rede, e o sujeito só tem ar. Não há caminho físico, e nenhum desenho conserta isso.

O que dá para fazer é não deixar acontecer em silêncio. É disso que trata a §7.

---

## 2. Os três caminhos

**1. O piloto fala.** A gravação sobe para a sala (16 kHz, com nome, no histórico) e, se o rádio estiver conectado, sai no ar pelo próprio dispositivo dele. O rádio garante alcance, a rede garante qualidade e registro. Isto já é a Fase 1; não muda.

**2. O ar entra na sala.** Todo app que ouviu uma transmissão do ar pode subi-la. O sistema garante que **uma cópia só** seja reproduzida. É o assunto desta spec.

**3. Sala → ar.** Não existe automático. O piloto que achar importante **repete por voz**, que é o que ele já faz hoje com o rádio, e isso recai no caminho 1. Um botão de "mandar esta mensagem para o ar" fica registrado como ideia futura na §9.

A assimetria é deliberada. O caminho 2 entrega o caso que motiva o projeto — o solo ouvindo o ar — e não precisa de arbitragem nenhuma. O caminho 3 precisaria de arbitragem, e é a metade cara. Deixá-lo humano é o que permite apagar a §6.4 da spec anterior.

---

## 3. Uma fala, várias cópias

### 3.1 O princípio

O canal VHF é meio-duplex: **só existe uma transmissão no ar por vez**. Então duas capturas que se sobrepõem no tempo, na mesma sala, são a mesma transmissão — por física, não por heurística. É o mesmo raciocínio que a §2 da spec anterior já usava para supressão de eco ("janela de tempo, não identificação de locutor"), generalizado de um dispositivo para o grupo.

**A unidade é a rajada, não o segmento.** Dois receptores cortam os 5 s em pontos diferentes: o gatilho de energia não dispara no mesmo instante, o pré-roll de 300 ms parte de origens distintas, o hangover fecha em offsets distintos. Comparar segmento a segmento nunca casaria. Compara-se a rajada inteira, e o `flags bit2 = continued` da §4.3 da Fase 1 é o que diz onde uma rajada realmente termina.

**A tolerância tem teto conhecido.** O dispositivo fecha a recepção com `hangover_ms` (700 ms) de silêncio, então duas transmissões realmente distintas já nascem separadas por pelo menos isso. A tolerância de sobreposição tem que ser **menor que `hangover_ms`**, ou o sistema funde falas diferentes. Não é um chute solto: é um parâmetro amarrado a outro que já existe.

### 3.2 Três fontes de janela

O sistema inteiro tem uma ideia só, com três maneiras de saber a janela:

| Fonte | Quem sabe | Serve para |
|---|---|---|
| A própria transmissão | o dispositivo, desarmando a detecção durante o PTT + 500 ms de guarda | não capturar o próprio eco |
| Sobreposição observada | o servidor, agrupando capturas | escolher uma cópia entre N |
| Janela declarada | o app que pôs áudio no ar, anunciando | ninguém tratar como nova uma fala que já está na sala |

A terceira é nova, e a §3.3 explica por que ela é indispensável.

### 3.3 `captured_at` não basta: entra `aired_at`

A tentação é comparar a captura de rádio do C contra o `captured_at` da mensagem do A. Isso falha, e falha por um motivo que não dá para contornar com folga na tolerância.

**O intervalo entre falar e ir ao ar é variável e não é derivável.** São três coisas somadas, e nenhuma é constante:

- a marca d'água de transmissão (`ptt_watermark_ms`, 500 ms), que é config empurrável pelo app (§6 da Fase 1)
- os 150 ms de ativação do PTT
- **a espera pelo canal livre**, que é o termo grande: um `BURST_START` recusado por `CHANNEL_BUSY` é retentado pelo app enquanto a fala couber em `radio_relay_deadline_ms` — **até 10 s** (§7 da Fase 1)

Uma fala de 12:00:00 pode ir ao ar às 12:00:07 porque alguém estava transmitindo. A captura do C carimba 12:00:07. Aumentar a tolerância até cobrir 10 s destruiria a dedup, porque 10 s no rádio contêm várias falas distintas.

Então o app **declara** a janela. Ele sabe: o dispositivo notifica a transição para `TRANSMITTING` e a volta para `IDLE` (ou `UNDERRUN`) por `state`, e o app carimba as duas pontas com o relógio já corrigido contra o servidor, descontando a latência do BLE — a mesma disciplina que a §7 da Fase 1 já impõe ao `captured_at` do que veio do ar.

A divisão de trabalho dos três carimbos fica:

- **`created_at`** (servidor) — quando isto chegou; ordena o transporte e o catch-up
- **`captured_at`** (cliente) — quando isto foi dito; decide se toca
- **`aired_at`** (cliente) — quando isto ocupou o ar; decide se é a mesma fala que outro ouviu

### 3.4 Três camadas de supressão

O caso mais comum não precisa do servidor, e é bom que não precise: quando todo mundo tem rádio e internet, cada fala do A seria capturada e subida por B, C e D — três uploads de algo que a sala já tem do próprio A, com nome e em 16 kHz.

**Camada 1 — local, sem perguntar a ninguém.** Um app não sobe captura de rádio que se sobrepõe a uma janela de ar já conhecida por ele. Ele conhece pelo evento `air.window` (§5.2), que chega em tempo real.

O custo é um **compasso de espera** (`air_upload_grace_ms`, 2,5 s) antes de decidir subir, para dar tempo do anúncio chegar. Isso atrasa o upload, nunca a escuta: quem capturou já ouviu ao vivo pelo próprio rádio, e quem espera os 2,5 s é a equipe de solo, para quem isso não é nada.

**Camada 2 — espalhamento entre receptores.** Quando o áudio entrou na sala **só pelo ar** — o piloto sem internet, ou o piloto que não usa o app — não existe janela declarada para suprimir contra, e vários apps vão querer subir. Cada um espera um atraso dentro de `air_upload_backoff_max_ms` antes de começar, e reavalia quando o tempo passa: se `message.new` de uma captura sobreposta chegou nesse meio tempo, ele desiste.

O atraso é **proporcional à qualidade medida da captura**: quem ouviu melhor espera menos e costuma ganhar. Não é ranking honesto — ganho de ADC, squelch e antena variam entre aparelhos e os números não são comparáveis de verdade —, mas nunca é pior que sorteio, e no caso típico faz a melhor cópia vencer de graça. Um componente aleatório pequeno desempata.

**Camada 3 — servidor, rede de proteção.** Quem chegar primeiro com uma rajada de `origin=radio` fica com o `air_burst_id`. Rajada sobreposta que chegar depois recebe `duplicate_of` apontando para ela, e a resposta do **primeiro segmento** já diz isso — o perdedor **aborta os segmentos seguintes** em vez de gastar rede com o resto.

Três camadas, cada uma cobrindo o que a anterior deixou passar, e a mais cara é a que quase nunca roda.

### 3.5 O que toca

Regra única, e ela não é nova: **item vencido não toca, sem exceção** (§2.1 da Fase 2). Sobre isso, duas adições:

- **Cópia marcada como `duplicate_of` nunca toca**, em ninguém. Fica no histórico, agrupada sob a canônica, ouvível por toque.
- **Se o meu próprio rádio estava recebendo naquela janela, eu já ouvi.** A cópia que vem da sala não toca no meu aparelho, mesmo sendo a canônica. É decisão local, não precisa concordar com a de mais ninguém: o fato que ela usa — "o meu dispositivo estava em `RECEIVING`" — só o meu aparelho conhece.

### 3.6 Atribuição retroativa

O piloto A sem internet fala; a captura do B entra na sala anônima, como toda voz vinda do ar. Quando o A recupera sinal, a subida atrasada dele completa (até `delivery_deadline_ms`) e traz `aired_at`.

O servidor casa essa janela com a rajada anônima e **substitui**: a fala ganha o nome do A e o áudio de 16 kHz, e a captura de rádio vira `duplicate_of` dela, retroativamente. O registro se conserta sozinho.

Isso resolve, sem nenhum mecanismo novo, a lacuna que a §1.1 da spec anterior registrava como aceita: *"quem tem só rádio não é membro da sala e não tem como ser identificado"*. Continua verdade para quem não usa o app. Deixa de ser verdade para quem usa e estava só sem sinal — que é o caso frequente.

---

## 4. O que morre: a eleição de ponte

A §6.4 da spec anterior sai inteira: candidatura, eleição pelo servidor, `bridge.changed`, heartbeat de 10 s, promoção do próximo em 30 s, estado efêmero em Redis. Com ela saem o módulo `bridge/` da §5.1 e a questão em aberto *"política de retentativa quando a ponte cai no meio de uma fila de transmissão"* da §9 — não há ponte, não há fila, não há queda.

Os dois argumentos que sustentavam a eleição (§2 da spec anterior) foram erodidos por decisões posteriores, e vale registrar como:

**"Uma fala do ar seria injetada várias vezes na sala."** Resolvido pela §3.4 desta spec. Injetar várias vezes deixou de ser problema e virou o mecanismo — é a redundância de antenas que faz o piloto sem sinal chegar ao solo.

**"Uma mensagem da sala seria transmitida no ar por várias rádios simultaneamente."** Continua verdade, mas perdeu o objeto: não existe mais mensagem da sala indo ao ar por conta própria. O caminho 3 é humano e raro. Se duas pessoas resolverem repetir a mesma coisa, uma pega `CHANNEL_BUSY` e o pior resultado é a mesma fala indo ao ar duas vezes — visível, humano, e resolvido como sempre foi resolvido no rádio: alguém diz "já passei".

**O que não morre:** o transmissor do dispositivo continua inteiro — PTT, canal livre, guarda, underrun, PTT contínuo entre segmentos —, porque o piloto transmite a própria fala. O que morre é a **arbitragem entre vários candidatos**, não a transmissão.

**O anúncio de capacidade sobrevive.** O `tem ESP32 conectado: sim/não` da §6.4 continua sendo enviado na entrada da sala e a cada mudança. Deixou de ser entrada de arbitragem e virou informação de tela (§7).

---

## 5. Contrato

### 5.1 Campos novos na mensagem

| Campo | Quando | Significado |
|---|---|---|
| `air_burst_id` | `origin=radio` | identificador do agrupamento; igual para todas as capturas da mesma transmissão |
| `duplicate_of` | `origin=radio` | `burst_id` da rajada canônica; `null` se esta é a canônica |
| `capture_quality` | `origin=radio`, opcional | escore local de qualidade da captura, 0–100; entrada do backoff da §3.4 e da §8 |

A resposta ao `POST` do **primeiro segmento** de uma rajada `origin=radio` já carrega `duplicate_of`. É por ela que o perdedor sabe que pode parar.

### 5.2 Janela de ar

```
POST /rooms/{room}/air-windows
{ "burst_id": "...", "started_at": "...Z", "ended_at": "...Z", "complete": true }
```

Declara que aquela rajada ocupou o ar naquele intervalo. `complete: false` quando o `UNDERRUN` cortou a transmissão no meio — o áudio saiu parcialmente, e a janela ainda vale para dedup do que saiu.

É recurso separado da mensagem, e não campo dela, por uma razão de sequência: o upload e a ida ao ar correm **em paralelo** e terminam em ordem imprevisível. Com o canal ocupado, o ar pode sair 7 s depois de a mensagem já estar na sala. Campo obrigatório no `POST /messages` travaria o upload esperando o rádio; campo opcional preenchido depois seria um `PATCH` com o mesmo desenho e um nome pior.

Ecoa como evento `air.window` no canal da sala, com o mesmo corpo. É o que alimenta a camada 1 da §3.4.

O mesmo recurso serve, sem alteração, ao botão de repasse manual da §9: o que ele declara é "esta rajada ocupou o ar de T1 a T2", e quem pôs o áudio lá é irrelevante para quem precisa deduplicar.

### 5.3 Config nova

| Config | Padrão | Significado |
|---|---|---|
| `air_upload_grace_ms` | 2500 | quanto o app segura uma captura antes de decidir subir |
| `air_dedup_tolerance_ms` | 400 | folga na comparação de sobreposição; **tem que ser menor que `hangover_ms`** |
| `air_upload_backoff_max_ms` | 600 | teto do espalhamento entre receptores |

Entregues por `GET /config` como todos os outros orçamentos, pelo motivo da §2 da Fase 2: são chutes a calibrar em campo, e calibrar não pode depender de publicar versão nova na loja. Aqui isso pesa mais que o normal — a tolerância certa depende do squelch dos rádios que o grupo usa, e não tem como ser descoberta em bancada.

### 5.4 Presença

O membro passa a carregar `has_radio` (booleano, anunciado pelo app) além do que a presença nativa do canal já dá. O servidor guarda o último valor conhecido com o instante em que foi visto, para a inferência da §7.

### 5.5 Revogado

`bridge.changed` sai. Nenhum cliente precisa passar a ignorá-lo — ele simplesmente deixa de ser publicado.

---

## 6. Ordem de chegada e o caso de um uplink só

Quando **um único piloto tem internet**, ele vira o uplink do grupo inteiro: tudo que o ar carrega chega ao solo por ele, e só por ele.

O desenho funciona sem alteração, mas repare que é justamente aí que a camada 1 da §3.4 **não faz nada** — não há cópia da sala para suprimir contra, porque ninguém mais está subindo. Ele sobe tudo que ouve, sozinho, e a bateria e os dados de uma pessoa carregam o grupo sem que ela tenha sido consultada.

O app tem que avisar: *"você é o único com sinal; o grupo está subindo por você."* É informação que muda decisão — o piloto pode querer poupar bateria, ou pode querer justamente garantir que continua de pé.

---

## 7. A gaveta de pilotos

Ela deixa de responder "quem está na sala" e passa a responder a pergunta que o piloto realmente tem:

> **quem vai me ouvir se eu falar agora?**

Três estados, derivados dos dois eixos da §1:

| Estado | Condição | O que significa |
|---|---|---|
| **Te ouve pela rede** | online | recebe pela sala, com nome e qualidade |
| **Está no ar** | `has_radio`, online ou não | ouve pelo rádio, se estiver no alcance |
| **Não te ouve** | offline e sem `has_radio` | incomunicável |

**A distinção do meio é a que importa.** Um piloto que ficou offline mas entrou na sala com o rádio conectado **não sumiu** — está lá, ouvindo o ar, e você fala com ele normalmente. Mostrar só "offline" faria o piloto achar que perdeu o cara quando não perdeu. É a diferença entre *sem sinal* e *incomunicável*, e num resgate essas duas palavras não podem aparecer iguais na tela.

Por isso a §5.4 guarda o **último valor conhecido** de `has_radio` com o instante: para quem está offline, é a única evidência que existe, e é evidência boa — rádio conectado não se desconecta por falta de cobertura de dados.

**No PTT, um resumo, não uma lista.** Em voo ninguém lê lista. Ao lado do botão cabe *"4 te ouvem, 1 não"*; o detalhe fica na gaveta para quem for olhar.

**Honestidade sobre o que o sistema não sabe.** "Está no ar" não é "vai te ouvir": pode estar a 30 km atrás de um morro. O app não promete alcance, do mesmo jeito que nunca verifica se algum rádio está mesmo na frequência declarada (§3 da Fase 2). A §8 é o caminho para isso deixar de ser suposição.

---

## 8. Alcance observado — registrar agora, usar depois

Se a captura do C se sobrepõe à janela de ar declarada pelo A, isso é **prova de que o rádio do C ouviu o A**. O servidor já vai ter esse dado: é exatamente o que o agrupamento da §3.4 produz e depois joga fora.

As capturas duplicadas, que o desenho trata como desperdício a ser evitado, são na verdade uma **medição contínua de quem alcança quem**. "O C te ouviu no rádio há 2 minutos" passa a ser afirmação com evidência, e para a equipe de solo isso vale muito.

**Esta spec não desenha essa feature.** Ela só exige que o par (rajada canônica, quem capturou e com que qualidade) seja **persistido** em vez de descartado junto com a duplicata. É uma tabela de junção; sem ela, a informação se perde no instante em que a duplicata é marcada, e reconstruí-la depois é impossível.

---

## 9. Consequências fora desta spec

Coisas que este desenho reordena ou amarra em outras fases. Nenhuma é implementada aqui; todas custam caro se descobertas depois.

**O acionamento do PTT sobe de prioridade.** A §5.6 da spec anterior trata botão externo e fone Bluetooth como polimento de Fase 5. Mas o motivo de existir o app é que o PTT do rádio é difícil de acionar em voo com as duas mãos ocupadas e o microfone capta vento. Se o PTT do app for um botão na tela, o app troca um botão ruim por um pior. O headset com botão mapeável e microfone próximo à boca deixa de ser acessório e vira hardware do sistema, e precisa ser homologado cedo — ele decide o que comprar.

**VOX exige pré-roll no app.** Quando o disparo por voz entrar, o app terá o mesmo problema que o dispositivo resolve com buffer circular (§4.3 da Fase 1): quando o detector confirma que é fala, os primeiros 150 ms já passaram, e toda mensagem perde a primeira sílaba. A captura já é PCM em stream — segurar ~300 ms de buffer circular custa quase nada agora e é retrabalho na camada de áudio depois.

**VOX reabre a decisão de "sempre vai ao ar".** Hoje toda fala do piloto sai no rádio dele, e isso é seguro porque o disparo é o PTT, que é deliberado. Com VOX, um disparo falso por vento passa a ocupar o VHF sozinho — rajada de ruído no canal que precisa estar livre para emergência, tráfego e pouso. Quando o VOX for desenhado, isto volta para a mesa; não é decisão pendente agora.

**Dados por som exigem um tipo de quadro reservado no BLE, já.** A ideia futura de mandar posição e ID junto com a voz (AFSK 1200 baud, o que o APRS faz nesta mesma faixa há décadas, no modo Mic-E: rajada curta logo depois da voz, mesmo canal) esbarra em algo que precisa ser decidido antes: **a rajada de dados não pode passar pelo ADPCM de 8 kHz.** ADPCM é com perda e destrói tom de 1200 baud. Modular e demodular são trabalho do dispositivo, em PCM, e o BLE precisa de um tipo de quadro `data` distinto de `audio` — reservado desde já, no mesmo cabeçalho da §3.2 da Fase 1. Uma linha hoje, camada de áudio reescrita depois.

Dois efeitos colaterais na mesma direção: o corte de `segment_max_ms` não pode cair no meio de uma rajada de dados, e o app não pode aparar o final de uma transmissão — é lá que o dado mora. Quando o ID vier por esse caminho, a dedup da §3 deixa de ser janela de tempo e passa a ser identificador exato; a janela continua sendo o fallback que sempre funciona.

**Repasse manual para o ar.** O botão de "mandar esta mensagem para o rádio" é ideia futura, não escopo. O contrato já a comporta: o repassador declara a janela pela §5.2 e ninguém trata como nova uma fala que já está na sala. Registrado para que a §5.2 não seja redesenhada quando ela chegar.

**Bateria.** O rádio primeiro tem custo contínuo: todo app avaliando o que ouve, subindo o que sobrou, com BLE conectado e foreground service de pé, num voo de 4 horas. O aborto do perdedor (§3.4) e o compasso de espera atacam o desperdício, mas o consumo só se conhece medindo em voo. É risco de campo, não de bancada.

---

## 10. Faseamento revisado

A Fase 3 da spec anterior ("Integração: a ponte") era a fase mais pesada do projeto: eleição, heartbeat, failover, relay bidirecional, supressão de eco, fila de transmissão. Ela se parte em duas, e a metade valiosa é a barata:

**Fase 3 — O ar entra na sala.** Captura do dispositivo subindo para a sala, as três camadas de supressão, `aired_at` e janela de ar, atribuição retroativa, a gaveta da §7. Sem eleição, sem relay da sala para o ar, sem arbitragem. Entrega o caso do resgate inteiro.

**Fase 3.5 (se houver) — Repasse manual.** O botão da §9. Isolado, pequeno, e o contrato já o comporta.

O que sobrava da Fase 3 antiga — eleição e failover — não vai para lugar nenhum: deixa de existir.

---

## 11. Riscos

- **A tolerância de sobreposição não tem valor certo em bancada.** Depende do squelch dos rádios do grupo. Larga demais funde falas distintas; estreita demais repete a mesma fala. É o parâmetro que mais precisa de voo real, e é por isso que ele vem do servidor.
- **Rajadas fundidas assimetricamente.** O receptor A pode fundir em uma rajada o que o receptor B separa em duas, por diferença de squelch. O agrupamento por sobreposição transitiva acaba juntando as três, e se a rajada errada vencer, a cauda de uma fala pode não tocar. Mitigação a avaliar: preferir, dentro do grupo, a rajada de maior extensão.
- **Bateria e dados no caso de uplink único** (§6).
- **O compasso de espera atrasa o caso que mais importa.** Os 2,5 s da camada 1 incidem justamente sobre a captura do piloto sem internet, que é a razão de tudo isto existir. Contra um `playback_deadline_ms` de 30 s há folga, mas a folga não é infinita e o valor precisa ser medido, não assumido.

---

## 12. Questões em aberto

- Escore de `capture_quality`: energia média, pico, estimativa de SNR, ou fração de pedaços descartados na congestão; qualquer escolha serve ao backoff, mas a §8 precisa de uma que signifique a mesma coisa em aparelhos diferentes
- Se o `playback_deadline_ms` deve ser o mesmo para quem está no solo; uma fala de 90 s ainda é útil para o resgate e é ruído para o piloto
- Schema exato do agrupamento no servidor: tabela de rajadas separada, ou colunas na mensagem
- Como a UI agrupa e apresenta as capturas não canônicas no histórico
- Se o anúncio de `has_radio` precisa de algum sinal de vida próprio, ou se a presença do canal basta
