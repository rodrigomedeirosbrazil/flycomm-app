# Design: área de configuração e usabilidade da Fase 2

Detalha o item "Design de UI da sala e do histórico" deixado em aberto na
seção 10 da [spec da Fase 2](../../specs/2026-09-13-fase-2-sala-e-backend-design.md).

## 0. Este documento não muda o contrato

Nada aqui precisa de endpoint novo, campo novo ou evento novo. Três das rotas
que ele expõe — `PATCH /me`, `POST /rooms`, `POST /rooms/{id}/leave` — já estão
implementadas no cliente e **nunca são chamadas pela interface**. O trabalho é
tela, não protocolo.

Isso é afirmação verificável, e é de propósito: a regra do repositório é que
divergência de contrato vira commit no `flycomm`, não ajuste local. Se durante a
implementação algo aqui exigir um campo que o servidor não manda, a resposta
certa é parar e avisar.

---

## 1. O problema

O app sabe fazer mais do que deixa fazer, e a parte que falta é a que o piloto
mais sente.

**Ele não tem nome.** O nome de exibição é inventado no arranque —
`'Piloto ${identifier.substring(8, 12)}'` — e é esse hex que aparece na presença
da sala e em cada linha do histórico dos outros. Pior: ele só vale na criação.
O servidor ignora `display_name` na recuperação, de modo que o nome sorteado no
primeiro arranque é permanente. `AuthRepository.updateDisplayName` existe,
implementa o `PATCH /me` e é código morto.

**Ele não consegue criar sala.** Só entrar por código. O primeiro piloto de um
grupo depende de uma sala semeada pelo `docker compose`.

**Ele não consegue sair de uma sala**, nem renomear uma, nem ler o código de
convite de dentro da sala — que é exatamente onde ele está quando alguém
pergunta pelo rádio como entrar.

**Ele não sabe se está conectado.** `RoomSession.connectionState` é exposto e
ninguém escuta. Com o WebSocket caído, a tela é idêntica a uma sala em silêncio.

**Ele não sabe quem o ouve.** A barra de presença junta os nomes numa linha só,
que corta sem avisar, e não distingue quem entrou na sala de quem está
conectado agora — que é a única das duas perguntas com consequência operacional.

---

## 2. Identidade

### 2.1 Onde o nome mora

`AppScope` guarda `userId` e é imutável (`updateShouldNotify => false`). A tela
de configuração precisa ler o nome atual e escrevê-lo.

`AppScope.user` passa a ser um `ValueNotifier<AuthenticatedUser>`, e `userId`
continua existindo como getter em cima dele. É a menor mudança que resolve: o
app não usa nenhuma biblioteca de gerência de estado, e um `ValueNotifier` é o
que o próprio Flutter oferece para um valor que muda em um lugar e é lido em
outro. Introduzir uma biblioteca para um campo seria pagar caro por pouco.

### 2.2 O nome gerado continua

O primeiro arranque **não** pergunta o nome. O app entra direto na lista de
salas com o nome sorteado, e quem quiser trocar vai à configuração.

A alternativa — uma tela de boas-vindas obrigatória — foi considerada e
recusada. Ela garantiria que ninguém nunca aparece como `Piloto a3f2`, ao preço
de uma tela a mais no arranque e de um estado "ainda não tem nome" para
persistir e para tratar em toda falha de rede do bootstrap. O arranque deste app
já tem um caminho de erro delicado — o `GET /config` que falha enquanto o iOS
pergunta pela permissão de Rede Local — e engrossá-lo não vale o ganho.

### 2.3 O que o cliente valida

`display_name` é 1–60 no contrato (§6.2.1). O campo valida isso antes de enviar.

Não é zelo: descobrir o limite por um 422 é uma ida ao servidor para aprender
uma constante que já está escrita na spec, e em rede de campo essa ida custa
segundos com o piloto olhando para um botão que não responde.

---

## 3. A tela de configuração

Arquivo novo: `lib/ui/settings_screen.dart`. Entrada por ícone de engrenagem na
AppBar da lista de salas, que é a raiz do app.

**Você** — o campo de nome e um botão Salvar, com estado explícito de salvando,
salvo e erro. Salvar é explícito, não ao perder o foco: um campo que aceita a
digitação e não diz se gravou é pior que um campo que não existe, porque o
piloto vai embora achando que trocou.

**Diagnóstico** — quatro coisas que hoje não têm onde ser vistas:

- o servidor com que este build fala (`Env.httpBase`), que é `--dart-define` e
  muda de rede para rede
- os orçamentos do `GET /config`, em texto legível. Quando uma fala é descartada
  por vencida, o prazo que a descartou não está em lugar nenhum da interface
- o desvio atual do relógio contra o servidor
- **o log de botões de mídia**, que sai da AppBar da sala

O log é ferramenta de bancada — existe para responder "o que este fone emite em
cada gesto" — e está hoje no primeiro nível da tela que se opera em voo. A
configuração é onde ele pertence enquanto a pergunta não estiver respondida.

---

## 4. Lista de salas

- **`+` na AppBar → Nova sala**, com nome e frequência opcional. Chama
  `rooms.create()`, que deixa de ser código morto, e abre a sala criada — mesmo
  desfecho de entrar por código, porque quem acabou de criar quer o código de
  convite, que está lá dentro.
- **O FAB continua "Entrar por código".** Num grupo de 3–15 pilotos, um cria e
  o resto entra: entrar é a ação frequente e fica no alvo grande. Ela ganha
  indicador de progresso — hoje o toque em "Entrar" não devolve nada por um
  segundo inteiro — e o `TextEditingController` passa a ser descartado.
- **Toque longo na linha copia o código de convite.**
- **O `RefreshIndicator` passa a envolver também o estado vazio e o de erro**,
  com `AlwaysScrollableScrollPhysics`. Hoje ele só envolve a lista cheia, então
  o piloto que é adicionado a uma sala enquanto olha para "Nenhuma sala ainda"
  não tem como atualizar.
- **O erro ganha "Tentar de novo".** Hoje é um `Text` sem saída, enquanto a tela
  de arranque — que falha pelo mesmo motivo — tem botão.

---

## 5. Tela da sala

A AppBar fica com **nome · frequência · overflow**. O log de mídia saiu (§3), e
o overflow recebe três ações que não existem hoje:

**Renomear sala.** `rooms.update(name:)`. Sem `setState`: a mudança volta por
`room.updated` e chega em todo mundo sem recarregar, do mesmo jeito que a
frequência já faz.

**Código de convite.** Diálogo com o código em fonte grande e monoespaçada,
mais Copiar. Grande porque ele é ditado em voz alta, às vezes pelo próprio
rádio — é a mesma razão pela qual o alfabeto do código não tem `0`/`O` nem
`1`/`I`.

**Sair da sala.** `rooms.leave()`, com confirmação que diz a verdade inteira:
você para de receber, o histórico deste voo continua no aparelho, e voltar exige
o código de novo. Confirmada, a tela da sala fecha e o piloto volta para a lista,
já sem ela. O histórico é 100% local e permanente, e o servidor não é
arquivo — omitir isso faria a confirmação parecer mais destrutiva do que é, e
uma confirmação que exagera treina o piloto a não ler as próximas.

### 5.1 Permissão de microfone

O aviso "Sem permissão de microfone: você só ouve" ganha botão que abre os
ajustes do sistema (`openAppSettings`, já disponível no `permission_handler`),
**e** o app revalida a permissão quando volta do segundo plano.

A revalidação é a metade que importa: sem ela o piloto concede a permissão nos
ajustes, volta para o app e encontra a mesma frase dizendo que ele só ouve. Ele
não tem como saber que o texto é que está velho.

---

## 6. Quem está ouvindo

A funcionalidade nova desta rodada, e a que carrega mais decisão.

### 6.1 São duas perguntas, e só uma tem consequência

`session.current.members` é o **quadro** da sala: quem entrou. Vem da resposta
HTTP e sobrevive ao `room.updated`, porque o evento traz só
`{id, name, frequency_hz}` e o `copyWith` do `ReverbClient` preserva o resto.

`session.presence` é quem está **conectado agora**, com `id` e `display_name`
vindos do `presence.hash` do canal.

A segunda é a que decide alguma coisa: quem não está na presença **não te ouve
ao vivo**. Não é estado social, é estado operacional, e é a informação que
responde "dá para falar pelo app, ou tem que pegar o rádio".

### 6.2 A barra de presença vira a porta

Sem gaveta. Uma `endDrawer` precisa ou de swipe da borda — que disputa com o
gesto de voltar nas duas plataformas — ou de um ícone de 24 px na AppBar que
esta mesma spec está esvaziando. A barra de presença já existe, é de largura
inteira, e já teria que virar tocável para resolver o corte dos nomes. Usá-la
como porta é uma afordância em vez de duas, e um alvo operável de luva.

**A barra** passa a ser `● 4 de 8 ouvindo · Ana, Bruno, … ›`, com os nomes
truncados por `ellipsis`. O ponto é o indicador de conexão: a mesma linha
responde "eu estou conectado?" e "quem me ouve?", que são a mesma pergunta vista
das duas pontas.

**A folha** (`showModalBottomSheet`) lista os pilotos em dois grupos —
**ouvindo agora** em cima, **fora** embaixo — com a sua linha marcada como Você.

### 6.3 A lista é a união, não o quadro

Quando alguém entra na sala com você já dentro dela, **não existe evento que
avise**: `room.updated` carrega só nome e frequência. O quadro em memória fica
velho, e o recém-chegado apareceria na presença sem aparecer na lista.

A lista é então a união dos dois conjuntos, casada por `id`. Isso a cura sozinha
sem endpoint novo e sem tocar no contrato — e a hierarquia é honesta: a presença
é a verdade viva, o quadro é a última fotografia HTTP.

### 6.4 Com o socket caído, a folha não mente

Numa queda, `_scheduleReconnect` **não** limpa `_members` — só o `disconnect()`
explícito limpa. A lista não fica vazia: fica **velha**. Sem tratamento, a folha
mostraria oito nomes como "ouvindo" no exato momento em que o app não faz ideia
de quem está lá.

Em `disconnected`, a folha apaga a distinção e diz
**"Reconectando — não dá para saber quem está ouvindo"**, mostrando o quadro sem
marcação de estado. Mostrar verde com o socket caído é o tipo de silêncio
explicado que o resto deste app existe para evitar.

### 6.5 "Fora" vai parecer bug, e não é

**Um Android com a tela apagada cai da presença de propósito.** Sem Foreground
Service — Fase 4 —, ele realmente para de receber. O indicador vai estar certo
justamente quando parecer errado, e isso precisa estar escrito antes de a
primeira bancada reportá-lo.

### 6.6 O cruzamento é uma função pura

`lib/room/roster.dart`, sem `dart:ui`: recebe o quadro, a presença, o estado da
conexão e o meu `id`; devolve os grupos prontos. A regra de união, de
agrupamento e o caso de conexão caída são a parte do recurso que tem como dar
errado em silêncio, e são testáveis em `flutter test` no host — sem emulador,
sem servidor. Deixá-las dentro do widget tornaria a única parte arriscada a
única parte não testada.

### 6.7 O que fica de fora

"Falou pela última vez há X minutos". É calculável do histórico local, mas é a
informação que a lista de mensagens já dá logo acima da barra.

---

## 7. Ao vivo

**Háptico no PTT da tela**: `heavyImpact` ao apertar, `lightImpact` ao soltar.
Hoje o botão da tela não devolve nada ao tato, e ele é operado em voo, de luva,
com o piloto olhando para fora.

É seguro porque `pressPtt` toca o `cues.ready()` **até o fim** antes de abrir a
captura: o háptico acaba antes de o microfone existir, e o motor de vibração não
entra na gravação. A ordem dos quatro passos do `pressPtt` não muda.

**Repetir a última**: botão ao lado do PTT que toca a última fala **recebida**
com áudio no aparelho. "Diga de novo" é a afordância mais antiga do rádio, e
hoje ela exige achar a linha certa numa lista.

Recebida e não qualquer uma: a própria fala o piloto acabou de dizer.

**E é a rajada inteira, não o último segmento.** Uma fala de 12 s são três
mensagens com o mesmo `burst_id` e índices 0, 1 e 2 (§5 da spec da Fase 2).
Repetir só a mais nova devolveria os últimos dois segundos de uma frase — o
suficiente para parecer que o botão funciona e para não entregar a informação,
que é o pior dos dois. Então: a rajada mais nova de outro autor com áudio no
aparelho, tocada em ordem de índice crescente.

A seleção da rajada é função pura sobre `List<LocalMessage>`, pelo mesmo motivo
do §6.6. A reprodução reaproveita o caminho de `playFromHistory` — que já marca
como ouvida — segmento a segmento, e **para no meio se o PTT for acionado**: o
meio-duplex vale para a repetição como vale para a fila.

---

## 8. Um defeito que este trabalho expõe

`playFromHistory` documenta que "entra na mesma fila e respeita o meio-duplex",
e chama `player.play()` direto, sem consultar `pttHeld`.

Hoje isso só acontece se o piloto tocar uma linha do histórico com um dedo
enquanto segura o PTT com o outro — raro o bastante para nunca ter aparecido.
Com o botão de repetir encostado no PTT, deixa de ser raro.

A correção entra nesta rodada: **uma voz por vez, e nada toca enquanto o PTT
está acionado** é invariante da spec, não conveniência do app. A reprodução por
toque continua ignorando o prazo — o piloto pediu para ouvir —, mas passa a
respeitar o meio-duplex, que é o que a própria documentação da função já
promete.

---

## 9. Critérios de conclusão

- O piloto troca o nome na configuração e o nome novo aparece na presença e no
  histórico do outro aparelho, sem reinstalar
- Um aparelho sem sala nenhuma cria uma sala pelo app, lê o código na tela da
  sala e o segundo aparelho entra por ele
- Sair da sala tira o aparelho da presença do outro, e o histórico daquela sala
  continua no aparelho que saiu
- Com o Wi-Fi desligado num aparelho, a barra do outro **não** o mostra como
  ouvindo; com o Wi-Fi desligado no próprio aparelho, a folha diz que não dá
  para saber, em vez de mostrar a lista velha
- Um terceiro aparelho que entra na sala aparece na folha dos outros dois sem
  que eles recarreguem
- Repetir uma fala de 12 s toca os três segmentos em ordem, sem buraco
- Segurar o PTT durante a repetição a interrompe, e não produz duas vozes
- Negar o microfone, concedê-lo nos ajustes e voltar ao app: o aviso some sem
  reiniciar

Os quatro primeiros exigem dois aparelhos contra o servidor real. `roster.dart`,
a seleção da última fala e a validação do nome rodam em `flutter test` no host.

---

## 10. Fora de escopo

- Tela de boas-vindas no primeiro arranque (§2.2)
- Trocar o servidor pela interface: ele é `--dart-define` e continua sendo
- Papéis na sala. O vínculo já nasce com `role`, todos `member`, ninguém
  checando nada — e continua assim
- Compartilhar o código por `Share` do sistema. Copiar resolve, e uma
  dependência nova não se justifica por um botão
- Busca no histórico, separadores de dia, "tocar todas as não ouvidas"
