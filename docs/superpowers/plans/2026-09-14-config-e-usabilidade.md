# Configuração e usabilidade — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dar ao piloto uma área de configuração onde ele escolhe o próprio nome, e expor pela interface as capacidades que o cliente já implementa e esconde — criar sala, sair de sala, ler o código de convite, saber quem está ouvindo.

**Architecture:** Nada de protocolo novo: `PATCH /me`, `POST /rooms` e `POST /rooms/{id}/leave` já existem em `lib/room/` e nunca são chamados. O trabalho é de `lib/ui/`, com três exceções que não são widget e por isso são testáveis no host — o cruzamento presença × quadro da sala (`lib/room/roster.dart`), a seleção da rajada a repetir (`lib/history/replay.dart`) e o meio-duplex de `RoomSession.playFromHistory`.

**Tech Stack:** Flutter 3.13+, Material 3, drift (SQLite), dio, `permission_handler`, `flutter_test`. Sem biblioteca de gerência de estado: o app usa `InheritedWidget` e passa a usar um `ValueNotifier` para o único valor que muda.

**Spec:** [2026-09-14-config-e-usabilidade-design.md](../specs/2026-09-14-config-e-usabilidade-design.md)

---

## Antes de começar

**O app se desenvolve contra o servidor de verdade.** Suba o `flycomm-server`
(`docker compose up -d`) e descubra o IP da sua máquina na LAN. Os quatro
`--dart-define` são obrigatórios e não têm padrão — sem eles o `main` aborta de
propósito. Escreva os flags literalmente, nunca por variável de shell expandida
sem aspas.

```bash
flutter run --dart-define=FLYCOMM_HTTP=http://SEU_IP:8000 --dart-define=FLYCOMM_WS_HOST=SEU_IP --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
```

**`flutter analyze` não sai limpo, e isso é o esperado.** A base tem **10
`info`** pré-existentes — `prefer_initializing_formals`, `use_null_aware_elements`
e um `unnecessary_underscores` — em arquivos que este plano não toca. O critério
de cada tarefa é **não somar nenhuma issue nova**, nunca "zero issues". Não
conserte esses lints de passagem: eles são ruído alheio ao trabalho e inflam o
diff de revisão.

```bash
flutter analyze 2>&1 | tail -3   # deve dizer "10 issues found."
```

**`flutter analyze` limpo e testes passando não provam que o app monta.** Os
defeitos mais caros desta base apareceram só no aparelho. As tarefas de widget
deste plano terminam em `flutter analyze` + commit, e a verificação de verdade é
a lista da seção final.

**Rodar os testes de unidade** (sem servidor, sem emulador):

```bash
flutter test test/room test/audio test/history test/ui
```

---

## Estrutura de arquivos

**Criar:**

| Arquivo | Responsabilidade |
|---|---|
| `lib/room/roster.dart` | Função pura: cruza quadro da sala × presença × estado da conexão e devolve os grupos prontos. Sem `dart:ui`. |
| `lib/history/replay.dart` | Função pura: acha a rajada recebida mais nova que dá para tocar. Sem `dart:ui`. |
| `lib/ui/frequency.dart` | `formatFrequency` e `FrequencyInput`, hoje espalhados entre duas telas e privados. |
| `lib/ui/settings_screen.dart` | A tela de configuração: nome e diagnóstico. |
| `lib/ui/roster_sheet.dart` | A barra de presença tocável e a folha de quem está ouvindo. |
| `test/room/roster_test.dart` | Testa `roster.dart`. |
| `test/history/replay_test.dart` | Testa `replay.dart`. |

**Modificar:**

| Arquivo | O quê |
|---|---|
| `lib/ui/app_scope.dart` | `userId` vira `user`, um `ValueNotifier<AuthenticatedUser>`. |
| `lib/app.dart` | Monta o notifier. |
| `lib/ui/rooms_screen.dart` | Entrada da configuração, criar sala, estados de lista, copiar código. |
| `lib/ui/room_screen.dart` | Overflow (renomear/código/sair), barra de presença, permissão de microfone, botão de repetir. |
| `lib/ui/ptt_button.dart` | Háptico. |
| `lib/room/reverb_client.dart` | `presenceNow` e `connectionNow` — o último valor, para quem assina depois do evento. |
| `lib/room/room_session.dart` | Meio-duplex em `playFromHistory`; `replayBurst`. |
| `test/room/room_session_test.dart` | Teste do meio-duplex. |

---

## Task 1: `AppScope.user` — de id para o usuário inteiro

A tela de configuração precisa ler e escrever o nome. `AppScope` é imutável e
guarda só `userId`.

**Files:**
- Modify: `lib/ui/app_scope.dart:22-56`
- Modify: `lib/app.dart:82-110`

- [ ] **Step 1: trocar o campo no `AppScope`**

Em `lib/ui/app_scope.dart`, no construtor, troque `required this.userId,` por
`required this.user,`. Depois troque a declaração do campo:

```dart
  /// Quem é o piloto. Muda num lugar só — a tela de configuração — e é lido em
  /// outro, que é exatamente o caso para o qual o Flutter oferece
  /// `ValueNotifier`. O app não usa biblioteca de gerência de estado e não
  /// precisa começar a usar por um campo.
  final ValueNotifier<AuthenticatedUser> user;

  int get userId => user.value.id;
```

`ValueNotifier` vem de `package:flutter/foundation.dart`, já reexportado pelo
`package:flutter/widgets.dart` que o arquivo importa. `AuthenticatedUser` mora
em `room/auth_repository.dart`, já importado.

- [ ] **Step 2: montar o notifier no bootstrap**

Em `lib/app.dart`, dentro de `_start()`, troque `userId: user.id,` por:

```dart
      user: ValueNotifier(user),
```

- [ ] **Step 3: verificar que nada mais lia `userId` de outro jeito**

```bash
cd /Users/rodrigo/dev/flycomm-app && grep -rn "userId" lib/ test/
```

Esperado: só a definição em `app_scope.dart` e o uso em
`room_screen.dart` (`rows[index].authorId == scope.userId`). O getter mantém
esse uso funcionando sem edição.

- [ ] **Step 4: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/app_scope.dart lib/app.dart && git commit -m "refactor: o escopo guarda o piloto, não só o id dele

A tela de configuração precisa ler e escrever o nome, e o AppScope é
imutável. Um ValueNotifier é o que o Flutter oferece para um valor que
muda num lugar e é lido em outro; userId continua existindo como getter,
então nenhum uso atual muda."
```

---

## Task 2: A tela de configuração e o nome do piloto

**Files:**
- Create: `lib/ui/settings_screen.dart`
- Modify: `lib/ui/rooms_screen.dart:74-76`

- [ ] **Step 1: criar a tela**

Crie `lib/ui/settings_screen.dart`:

```dart
import 'package:flutter/material.dart';

import 'app_scope.dart';

/// A configuração do piloto.
///
/// Existe por um motivo só, e é o nome: até aqui ele era sorteado no primeiro
/// arranque — `Piloto a3f2` — e permanente, porque o servidor ignora
/// `display_name` na recuperação. Quem o muda é `PATCH /me`, que estava
/// implementado e nunca era chamado.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  bool _seeded = false;
  bool _saving = false;
  bool _saved = false;
  String? _problem;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _controller.text = AppScope.of(context).user.value.displayName;
    _seeded = true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 1–60 é o limite do contrato (§6.2.1 da spec da Fase 2). Validar aqui não
  /// é zelo: descobrir por um 422 é uma ida ao servidor para aprender uma
  /// constante que já está escrita, e em rede de campo essa ida custa segundos
  /// com o piloto olhando para um botão que não responde.
  Future<void> _save() async {
    final scope = AppScope.of(context);
    final name = _controller.text.trim();

    if (name.isEmpty || name.length > 60) {
      setState(() => _problem = 'O nome tem de 1 a 60 caracteres.');
      return;
    }

    setState(() {
      _saving = true;
      _saved = false;
      _problem = null;
    });

    try {
      scope.user.value = await scope.auth.updateDisplayName(name);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _problem = 'Não deu para salvar: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Configuração')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Você', style: text.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            textCapitalization: TextCapitalization.words,
            maxLength: 60,
            // Salvar é explícito, e não ao perder o foco: um campo que aceita
            // a digitação e não diz se gravou é pior que um campo que não
            // existe, porque o piloto vai embora achando que trocou.
            onChanged: (_) {
              if (_saved || _problem != null) {
                setState(() {
                  _saved = false;
                  _problem = null;
                });
              }
            },
            decoration: const InputDecoration(
              labelText: 'Nome',
              helperText: 'É este nome que os outros pilotos veem na sala e no '
                  'histórico.',
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Salvar'),
              ),
              const SizedBox(width: 12),
              if (_saved)
                Row(children: [
                  Icon(Icons.check, size: 18, color: colors.primary),
                  const SizedBox(width: 4),
                  Text('Salvo', style: TextStyle(color: colors.primary)),
                ]),
              if (_problem != null)
                Expanded(
                  child: Text(
                    _problem!,
                    style: TextStyle(color: colors.error),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: abrir a tela pela lista de salas**

Em `lib/ui/rooms_screen.dart`, adicione o import:

```dart
import 'settings_screen.dart';
```

E troque o `appBar:` do `Scaffold` por:

```dart
        appBar: AppBar(
          title: const Text('Minhas salas'),
          actions: [
            IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Configuração',
            ),
          ],
        ),
```

- [ ] **Step 3: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 4: conferir no aparelho**

Abra o app, toque na engrenagem, troque o nome, salve. Esperado: aparece
"Salvo". Volte, entre numa sala com um segundo aparelho conectado e confira que
o nome novo aparece na presença dele.

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/settings_screen.dart lib/ui/rooms_screen.dart && git commit -m "feat: o piloto escolhe o próprio nome

Até aqui o nome era sorteado no arranque — 'Piloto a3f2' — e permanente,
porque o servidor ignora display_name na recuperação. PATCH /me estava
implementado e nunca era chamado.

Salvar é botão, não perda de foco: um campo que aceita a digitação e não
diz se gravou é pior que um campo que não existe."
```

---

## Task 3: Diagnóstico na configuração, e o log de mídia sai da sala

O log de botões de mídia é ferramenta de bancada e está hoje no primeiro nível
da tela que se opera em voo.

**Files:**
- Modify: `lib/ui/settings_screen.dart`
- Modify: `lib/ui/room_screen.dart` (remove `_showMediaButtonLog` e o `IconButton`)

- [ ] **Step 1: adicionar a seção de diagnóstico**

Em `lib/ui/settings_screen.dart`, adicione os imports:

```dart
import '../env.dart';
import 'media_button_log.dart';
```

Adicione o método ao `_SettingsScreenState`:

```dart
  /// Os orçamentos vêm de GET /config e nunca de constante no código. Quando
  /// uma fala é descartada por vencida, o prazo que a descartou não está em
  /// nenhum outro lugar da interface.
  static String _budget(Duration value) {
    final seconds = value.inMilliseconds / 1000;
    if (seconds >= 60) return '${(seconds / 60).toStringAsFixed(0)} min';
    return '${seconds.toStringAsFixed(seconds % 1 == 0 ? 0 : 1)} s';
  }

  void _showMediaButtonLog() {
    final buttons = AppScope.of(context).mediaButtons;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Sem `cues`: a latência de saída medida só existe onde o tom foi
      // montado, que é a tela da sala. O log dos comandos, que é a pergunta
      // que importa aqui, não depende dela.
      builder: (context) => MediaButtonLog(handler: buttons),
    );
  }
```

E acrescente, ao final da lista de `children:` do `ListView`:

```dart
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),
          Text('Diagnóstico', style: text.titleMedium),
          const SizedBox(height: 12),
          _Row('Servidor', Env.httpBase),
          _Row(
            'Relógio',
            AppScope.of(context).clock.isSynced
                ? 'sincronizado, desvio de '
                    '${AppScope.of(context).clock.skew.inMilliseconds} ms'
                : 'ainda não sincronizado',
          ),
          const SizedBox(height: 12),
          Text('Orçamentos de tempo', style: text.labelLarge),
          const SizedBox(height: 4),
          _Row('Toca sozinho até', _budget(AppScope.of(context).budgets.playbackDeadline)),
          _Row('Insiste em subir até', _budget(AppScope.of(context).budgets.deliveryDeadline)),
          _Row('Segmento', _budget(AppScope.of(context).budgets.segmentMax)),
          _Row('Recuperação olha', _budget(AppScope.of(context).budgets.catchupWindow)),
          _Row('Áudio vive no servidor', _budget(AppScope.of(context).budgets.blobTtl)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _showMediaButtonLog,
            icon: const Icon(Icons.headset_mic_outlined),
            label: const Text('Comandos de mídia recebidos'),
          ),
```

E, no fim do arquivo, o widget de linha:

```dart
/// Rótulo à esquerda, valor à direita. Só diagnóstico usa.
class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(label)),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ],
        ),
      );
}
```

- [ ] **Step 2: tirar o log da AppBar da sala**

Em `lib/ui/room_screen.dart`, apague o método `_showMediaButtonLog` inteiro e o
import `import 'media_button_log.dart';`. No `actions:` da `AppBar`, apague o
`IconButton` de `Icons.headset_mic_outlined`.

O campo `_cues` continua existindo — ele é descartado no `dispose` e passado à
`RoomSession`. Só o uso dele no log sai.

- [ ] **Step 3: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa. Se aparecer `unused_field` para `_cues`, você
apagou demais: ele ainda vai para `RoomSession(cues: cues)` e para o `dispose`.

- [ ] **Step 4: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/settings_screen.dart lib/ui/room_screen.dart && git commit -m "feat: diagnóstico na configuração, e o log de mídia sai da sala

Servidor, desvio do relógio e os orçamentos do GET /config não tinham
onde ser vistos — quando uma fala é descartada por vencida, o prazo que a
descartou não aparecia em lugar nenhum.

O log de botões de mídia é ferramenta de bancada e estava no primeiro
nível da tela que se opera em voo."
```

---

## Task 4: `lib/ui/frequency.dart` — juntar o que está espalhado

`formatFrequency` mora em `rooms_screen.dart` e `_FrequencyInput` é privado em
`room_screen.dart`. A caixa de criar sala precisa dos dois.

**Files:**
- Create: `lib/ui/frequency.dart`
- Modify: `lib/ui/rooms_screen.dart` (remove `formatFrequency`)
- Modify: `lib/ui/room_screen.dart` (remove `_FrequencyInput`, troca o import)

- [ ] **Step 1: criar o arquivo**

Crie `lib/ui/frequency.dart`:

```dart
import 'package:flutter/services.dart';

/// A frequência é guardada como inteiro em Hz e só vira texto aqui.
/// Nula é um estado honesto: "ainda não combinamos a frequência".
String formatFrequency(int? hz) {
  if (hz == null) return 'sem frequência';
  return '${(hz / 1000000).toStringAsFixed(3)} MHz';
}

/// Seis dígitos bastam para qualquer frequência das faixas do rádio, escrita
/// como MHz com decimais (145,550) ou como kHz (145550). O que passa disso é
/// ignorado em vez de recusado: no ar, o piloto não vai ler mensagem de erro.
class FrequencyInput extends TextInputFormatter {
  static final _allowed = RegExp(r'^[0-9]*[.,]?[0-9]*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue previous,
    TextEditingValue next,
  ) {
    if (!_allowed.hasMatch(next.text)) return previous;

    final digits = next.text.replaceAll(RegExp('[^0-9]'), '');

    return digits.length > 6 ? previous : next;
  }
}
```

- [ ] **Step 2: apagar as duas cópias e reapontar os imports**

Em `lib/ui/rooms_screen.dart`: apague a função `formatFrequency` do fim do
arquivo e adicione `import 'frequency.dart';`.

Em `lib/ui/room_screen.dart`: apague a classe `_FrequencyInput` do fim do
arquivo, troque `import 'rooms_screen.dart';` por `import 'frequency.dart';`, e
troque `inputFormatters: [_FrequencyInput()]` por
`inputFormatters: [FrequencyInput()]`.

- [ ] **Step 3: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 4: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/frequency.dart lib/ui/rooms_screen.dart lib/ui/room_screen.dart && git commit -m "refactor: formatar e digitar frequência moram juntos

Um estava numa tela e o outro, privado, na outra. Criar sala precisa dos
dois."
```

---

## Task 5: Criar sala

`rooms.create()` está implementado e nunca é chamado: o primeiro piloto de um
grupo depende de uma sala semeada pelo `docker compose`.

**Files:**
- Modify: `lib/ui/rooms_screen.dart`

- [ ] **Step 1: adicionar o método**

Em `_RoomsScreenState`, adicione:

```dart
  /// Cria e **abre** a sala criada, mesmo desfecho de entrar por código: quem
  /// acabou de criar quer o código de convite, que está lá dentro.
  Future<void> _createRoom() async {
    final scope = AppScope.of(context);
    final name = TextEditingController();
    final frequency = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nova sala'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nome da sala'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: frequency,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FrequencyInput()],
              decoration: const InputDecoration(
                labelText: 'Frequência (opcional)',
                suffixText: 'MHz',
                hintText: '145,550',
                helperText: 'Dá para combinar depois.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Criar'),
          ),
        ],
      ),
    );

    final chosen = name.text.trim();
    final rawFrequency = frequency.text.trim();
    name.dispose();
    frequency.dispose();

    if (confirmed != true || chosen.isEmpty || !mounted) return;

    final hz = rawFrequency.isEmpty
        ? null
        : scope.config.frequencyHzFromInput(rawFrequency);

    if (rawFrequency.isNotEmpty && hz == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Não consegui ler isso como uma frequência das faixas do rádio '
          '(136–174 e 400–470 MHz). Tente 145,550 ou 145550.',
        ),
      ));
      return;
    }

    try {
      final room = await scope.rooms.create(name: chosen, frequencyHz: hz);
      if (!mounted) return;
      _reload();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RoomScreen(room: room)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Não deu para criar: $error')));
    }
  }
```

- [ ] **Step 2: pôr o `+` na AppBar**

No `actions:` da `AppBar`, **antes** do `IconButton` de configuração:

```dart
            IconButton(
              onPressed: _createRoom,
              icon: const Icon(Icons.add),
              tooltip: 'Nova sala',
            ),
```

O FAB continua "Entrar por código": num grupo de 3–15 pilotos, um cria e o resto
entra, então entrar é a ação frequente e fica no alvo grande.

- [ ] **Step 3: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 4: conferir no aparelho**

Toque em `+`, crie uma sala sem frequência. Esperado: a sala abre. Volte: ela
está na lista.

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/rooms_screen.dart && git commit -m "feat: criar sala pelo app

rooms.create() estava implementado e nunca era chamado: o primeiro piloto
de um grupo dependia de uma sala semeada pelo docker compose.

Criar abre a sala criada, mesmo desfecho de entrar por código — quem
acabou de criar quer o código de convite, que está lá dentro."
```

---

## Task 6: Os estados da lista de salas

Quatro defeitos pequenos na mesma tela, e um deles impede o piloto de se
recuperar sozinho.

**Files:**
- Modify: `lib/ui/rooms_screen.dart`

- [ ] **Step 1: descartar o controlador e mostrar progresso ao entrar**

O `showDialog` em si não muda — ele já devolve `controller.text.trim()` pelo
`Navigator.pop`. O que muda é tudo que vem depois dele. Troque o trecho que hoje
começa em `if (code == null || code.isEmpty || !mounted) return;` por:

```dart
    controller.dispose();

    if (code == null || code.isEmpty || !mounted) return;

    setState(() => _joining = true);

    try {
      final room = await AppScope.of(context).rooms.join(code);
      if (!mounted) return;
      setState(() => _joining = false);
      _reload();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => RoomScreen(room: room)),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _joining = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Não deu para entrar: $error')));
    }
```

Declare o campo em `_RoomsScreenState`:

```dart
  bool _joining = false;
```

E no FAB, troque o `icon:` por:

```dart
          icon: _joining
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.qr_code),
```

com `onPressed: _joining ? null : _joinByCode,`.

- [ ] **Step 2: o erro ganha saída, e o vazio ganha refresh**

Troque o `builder:` do `FutureBuilder` por:

```dart
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              // A tela de arranque falha pelo mesmo motivo e tem botão; esta
              // não tinha, e o piloto ficava sem saída a não ser matar o app.
              return _Refreshable(
                onRefresh: _reload,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Não deu para buscar suas salas.\n\n${snapshot.error}',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar de novo'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final rooms = snapshot.data!;
            if (rooms.isEmpty) {
              // Envolvido no refresh de propósito: alguém pode te adicionar a
              // uma sala enquanto você olha para esta frase.
              return _Refreshable(
                onRefresh: _reload,
                child: const Text(
                  'Nenhuma sala ainda.\nCrie uma no + ou entre por um código.',
                  textAlign: TextAlign.center,
                ),
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
                    // O código é ditado em voz alta, às vezes pelo próprio
                    // rádio. Copiar tira o erro de transcrição do caminho.
                    onLongPress: () async {
                      await Clipboard.setData(
                          ClipboardData(text: room.inviteCode));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('${room.inviteCode} copiado'),
                      ));
                    },
                  );
                },
              ),
            );
          },
```

Adicione o import `import 'package:flutter/services.dart';` e, no fim do
arquivo, o widget:

```dart
/// Conteúdo centralizado que ainda assim aceita puxar para atualizar.
///
/// Um `Center` não rola, e `RefreshIndicator` só dispara sobre um scrollable
/// que aceita overscroll — daí o `AlwaysScrollableScrollPhysics` e a altura
/// forçada pelo `ConstrainedBox`.
class _Refreshable extends StatelessWidget {
  const _Refreshable({required this.onRefresh, required this.child});

  final VoidCallback onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () async => onRefresh(),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
}
```

- [ ] **Step 3: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 4: conferir no aparelho**

Com o backend derrubado, abra a lista: deve aparecer "Tentar de novo". Suba o
backend e toque nele. Com a lista vazia, puxe para baixo: deve atualizar.
Segure uma linha: deve copiar o código.

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/rooms_screen.dart && git commit -m "fix: a lista de salas ganha as saídas que faltavam

O erro não tinha botão — a tela de arranque falha pelo mesmo motivo e
tem — e o estado vazio não aceitava puxar para atualizar, então quem era
adicionado a uma sala enquanto olhava para 'Nenhuma sala ainda' não tinha
como descobrir.

Mais o controlador que vazava e o toque em Entrar que não devolvia nada
por um segundo inteiro."
```

---

## Task 7: O overflow da sala — renomear, código, sair

**Files:**
- Modify: `lib/ui/room_screen.dart`

- [ ] **Step 1: adicionar os três métodos**

Em `_RoomScreenState`, adicione:

```dart
  Future<void> _renameRoom() async {
    final session = _session!;
    final scope = AppScope.of(context);
    final controller = TextEditingController(text: session.current.name);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Renomear sala'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nome'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );

    final name = controller.text.trim();
    controller.dispose();

    if (confirmed != true || name.isEmpty) return;

    // Sem setState: a mudança volta por room.updated e chega em todo mundo sem
    // recarregar, do mesmo jeito que a frequência já faz.
    await scope.rooms.update(session.current.id, name: name);
  }

  /// O código em fonte grande e monoespaçada porque ele é **ditado em voz
  /// alta**, às vezes pelo próprio rádio — é a mesma razão pela qual o
  /// alfabeto dele não tem 0/O nem 1/I.
  Future<void> _showInviteCode() async {
    final code = _session!.current.inviteCode;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Código de convite'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              code,
              style: const TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Quem digitar isto entra na sala. Vale em minúscula, sem hífen '
              'e sem o FLY.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copiar'),
          ),
        ],
      ),
    );
  }

  /// A confirmação diz a verdade inteira, inclusive a parte tranquilizadora: o
  /// histórico é 100% local e permanente, e sair não o apaga. Uma confirmação
  /// que exagera o estrago treina o piloto a não ler as próximas.
  Future<void> _leaveRoom() async {
    final session = _session!;
    final scope = AppScope.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sair de ${session.current.name}?'),
        content: const Text(
          'Você para de receber as falas desta sala. O histórico deste voo '
          'continua no aparelho. Para voltar, precisa do código de convite de '
          'novo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sair'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await scope.rooms.leave(session.current.id);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _lastProblem = 'Não deu para sair: $error');
    }
  }
```

- [ ] **Step 2: pôr o overflow na AppBar**

No `actions:` da `AppBar`, depois do `TextButton.icon` da frequência:

```dart
          PopupMenuButton<String>(
            onSelected: (value) => switch (value) {
              'rename' => _renameRoom(),
              'code' => _showInviteCode(),
              'leave' => _leaveRoom(),
              _ => null,
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Renomear sala')),
              PopupMenuItem(value: 'code', child: Text('Código de convite')),
              PopupMenuItem(value: 'leave', child: Text('Sair da sala')),
            ],
          ),
```

**Atenção ao import:** a Task 4 removeu `import 'package:flutter/services.dart';`
deste arquivo — ele tinha ficado sem uso quando o `_FrequencyInput` mudou de
casa. `Clipboard` vem de lá, então **adicione o import de volta**:

```dart
import 'package:flutter/services.dart';
```

- [ ] **Step 3: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 4: conferir com dois aparelhos**

Renomeie a sala num: o nome muda no outro **sem recarregar**. Veja o código e
copie. Saia da sala: a tela fecha, a sala some da lista, e o outro aparelho
deixa de mostrar você na presença.

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/room_screen.dart && git commit -m "feat: renomear, ver o código e sair, de dentro da sala

rooms.leave() estava implementado e sem interface, e o código de convite
não aparecia justamente onde o piloto está quando perguntam por ele pelo
rádio.

O código vai em fonte grande e monoespaçada porque é ditado em voz alta —
a mesma razão pela qual o alfabeto dele não tem 0/O nem 1/I."
```

---

## Task 8: `roster.dart` — o cruzamento, em função pura

Presença e quadro da sala são duas perguntas, e só uma tem consequência: quem
não está na presença **não te ouve ao vivo**.

**Files:**
- Create: `lib/room/roster.dart`
- Test: `test/room/roster_test.dart`

- [ ] **Step 1: escrever os testes que falham**

Crie `test/room/roster_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/room/models.dart';
import 'package:flycomm/room/roster.dart';

void main() {
  Member pilot(int id, String name) =>
      Member(id: id, displayName: name, role: 'member');

  group('Roster.from', () {
    test('separa quem está ouvindo de quem está fora', () {
      final roster = Roster.from(
        known: [pilot(1, 'Ana'), pilot(2, 'Bruno'), pilot(3, 'Célia')],
        present: [pilot(1, 'Ana'), pilot(3, 'Célia')],
        connected: true,
        me: 1,
      );

      expect(roster.listening, 2);
      expect(roster.total, 3);
      expect(roster.certain, isTrue);
      expect(
        roster.entries.map((e) => (e.displayName, e.presence)),
        [
          ('Ana', PilotPresence.listening),
          ('Célia', PilotPresence.listening),
          ('Bruno', PilotPresence.away),
        ],
      );
    });

    test('marca quem sou eu', () {
      final roster = Roster.from(
        known: [pilot(1, 'Ana'), pilot(2, 'Bruno')],
        present: [pilot(1, 'Ana'), pilot(2, 'Bruno')],
        connected: true,
        me: 2,
      );

      expect(roster.entries.singleWhere((e) => e.isMe).id, 2);
    });

    test('inclui quem está na presença e não no quadro', () {
      // Não existe evento de entrada na sala: room.updated carrega só
      // {id, name, frequency_hz}. Sem a união, quem entra enquanto você está
      // dentro aparece na presença e some da lista.
      final roster = Roster.from(
        known: [pilot(1, 'Ana')],
        present: [pilot(1, 'Ana'), pilot(9, 'Zeca')],
        connected: true,
        me: 1,
      );

      expect(roster.total, 2);
      expect(roster.entries.map((e) => e.displayName), ['Ana', 'Zeca']);
    });

    test('com o socket caído não afirma nada sobre ninguém', () {
      // Numa queda o ReverbClient NÃO limpa os membros — só o disconnect()
      // explícito limpa. Então o perigo não é lista vazia, é lista confiante e
      // errada: oito nomes em verde no exato momento em que o app não faz
      // ideia de quem está lá.
      final roster = Roster.from(
        known: [pilot(1, 'Ana'), pilot(2, 'Bruno')],
        present: [pilot(1, 'Ana'), pilot(2, 'Bruno')],
        connected: false,
        me: 1,
      );

      expect(roster.certain, isFalse);
      expect(roster.listening, 0);
      expect(roster.total, 2);
      expect(
        roster.entries.every((e) => e.presence == PilotPresence.unknown),
        isTrue,
      );
    });

    test('ordena por nome dentro de cada grupo, sem depender de maiúscula', () {
      // 'Zeca' e 'ana' de propósito: por código UTF-16 'Z' (0x5A) vem antes de
      // 'a' (0x61), então a ordenação ingênua poria Zeca na frente. Com
      // ['zeca', 'Ana', 'bruno'] — o fixture anterior — os dois critérios dão o
      // mesmo resultado, e o teste passaria mesmo sem o toLowerCase.
      final roster = Roster.from(
        known: [pilot(1, 'Zeca'), pilot(2, 'ana'), pilot(3, 'bruno')],
        present: [pilot(1, 'Zeca'), pilot(2, 'ana'), pilot(3, 'bruno')],
        connected: true,
        me: 2,
      );

      expect(roster.entries.map((e) => e.displayName),
          ['ana', 'bruno', 'Zeca']);
    });
  });
}
```

- [ ] **Step 2: rodar e ver falhar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter test test/room/roster_test.dart
```

Esperado: falha de compilação — `Target of URI doesn't exist: 'package:flycomm/room/roster.dart'`.

- [ ] **Step 3: implementar**

Crie `lib/room/roster.dart`:

```dart
import 'models.dart';

/// O que o piloto precisa saber sobre outro piloto, e é uma coisa só: ele te
/// ouve **agora**? Não é estado social — quem não está na presença não recebe
/// a sua fala ao vivo, e a resposta certa para ele é o rádio.
enum PilotPresence { listening, away, unknown }

class RosterEntry {
  const RosterEntry({
    required this.id,
    required this.displayName,
    required this.presence,
    required this.isMe,
  });

  final int id;
  final String displayName;
  final PilotPresence presence;
  final bool isMe;
}

/// Cruza o **quadro** da sala (quem entrou, da resposta HTTP) com a
/// **presença** (quem está conectado agora, do canal) e o estado do meu
/// próprio socket.
class Roster {
  const Roster({
    required this.entries,
    required this.listening,
    required this.total,
    required this.certain,
  });

  final List<RosterEntry> entries;
  final int listening;
  final int total;

  /// `false` quando o meu socket está caído. A interface tem que checar isto
  /// **antes** de `listening`: numa queda o cliente não limpa os membros, então
  /// a lista não fica vazia, fica velha.
  final bool certain;

  static Roster from({
    required List<Member> known,
    required List<Member> present,
    required bool connected,
    required int me,
  }) {
    final presentIds = {for (final member in present) member.id};

    // A união, e não só o quadro: não existe evento de entrada na sala, então
    // quem entra enquanto você está dentro só aparece pela presença. O nome
    // vem do lado presente quando há um, por ser o aperto de mão mais recente
    // com o servidor.
    final merged = <int, Member>{
      for (final member in known) member.id: member,
      for (final member in present) member.id: member,
    };

    final entries = merged.values
        .map((member) => RosterEntry(
              id: member.id,
              displayName: member.displayName,
              presence: !connected
                  ? PilotPresence.unknown
                  : presentIds.contains(member.id)
                      ? PilotPresence.listening
                      : PilotPresence.away,
              isMe: member.id == me,
            ))
        .toList();

    // Ouvindo em cima, e dentro de cada grupo por nome. `toLowerCase` porque
    // o piloto escolhe o próprio nome e ninguém combina maiúscula.
    entries.sort((a, b) {
      final byGroup = a.presence.index.compareTo(b.presence.index);
      if (byGroup != 0) return byGroup;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });

    return Roster(
      // Imutável: o valor inteiro desta classe é ser um retrato confiável —
      // agrupado e ordenado. Devolver a lista que acabou de ser ordenada in
      // place deixaria quem recebe desfazer isso sem querer.
      entries: List<RosterEntry>.unmodifiable(entries),
      listening: connected ? presentIds.length : 0,
      total: merged.length,
      certain: connected,
    );
  }
}
```

A ordem dos valores em `PilotPresence` é significativa: `listening` antes de
`away` é o que faz `presence.index` ordenar os grupos. `unknown` no fim não
importa, porque quando ele aparece todos os itens o têm.

- [ ] **Step 4: rodar e ver passar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter test test/room/roster_test.dart
```

Esperado: `+5: All tests passed!`

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/room/roster.dart test/room/roster_test.dart && git commit -m "feat: o cruzamento de quem está ouvindo, em função pura

Quadro da sala e presença são duas perguntas, e só uma tem consequência:
quem não está na presença não te ouve ao vivo.

A lista é a união das duas porque não existe evento de entrada na sala —
room.updated carrega só {id, name, frequency_hz}. E com o socket caído
ela não afirma nada: numa queda o cliente não limpa os membros, então o
perigo não é lista vazia, é lista confiante e errada.

Fora do widget porque é a única parte disto que tem como dar errado em
silêncio, e assim roda em flutter test no host."
```

---

## Task 9: O último valor da presença e da conexão

A presença chega no `subscription_succeeded`, que acontece dentro de `open()` —
antes de existir tela. Um `StreamBuilder` que assine depois fica sem dado.

**Files:**
- Modify: `lib/room/reverb_client.dart`
- Modify: `lib/room/room_session.dart`

- [ ] **Step 1: guardar o estado da conexão e expor os dois**

Em `lib/room/reverb_client.dart`, ao lado de `final _members = <int, Member>{};`:

```dart
  ReverbConnection _connectionState = ReverbConnection.disconnected;
```

Em `_emitConnection`, antes de `_connection.add(state)`:

```dart
    _connectionState = state;
```

E, junto dos outros getters de stream:

```dart
  /// O último valor, para quem assina depois do evento.
  ///
  /// Os dois eventos que a tela da sala precisa acontecem dentro de `open()`,
  /// antes de existir widget: a presença chega no `subscription_succeeded` e a
  /// conexão vira `connected` logo ali. Um StreamBuilder que assinasse depois
  /// ficaria sem dado nenhum e desenharia a sala inteira como fora — que é
  /// justamente a informação errada mais alarmante que esta tela pode dar.
  RoomPresence get presenceNow =>
      RoomPresence(members: _members.values.toList(growable: false));

  ReverbConnection get connectionNow => _connectionState;
```

- [ ] **Step 2: repassar pela sessão**

Em `lib/room/room_session.dart`, junto de `Stream<RoomPresence> get presence`:

```dart
  RoomPresence get presenceNow => reverb.presenceNow;
  ReverbConnection get connectionNow => reverb.connectionNow;
```

- [ ] **Step 3: analisar e rodar os testes de sala**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze && flutter test test/room
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa. e todos os testes passando.

- [ ] **Step 4: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/room/reverb_client.dart lib/room/room_session.dart && git commit -m "feat: o último valor da presença e da conexão

Os dois eventos acontecem dentro de open(), antes de existir widget.
Quem assinar depois não recebe nada, e uma tela que lê só o stream
desenharia a sala inteira como fora."
```

---

## Task 10: A barra de presença vira a porta

**Files:**
- Create: `lib/ui/roster_sheet.dart`
- Modify: `lib/ui/room_screen.dart` (o `bottom:` da `AppBar`)

- [ ] **Step 1: criar a barra e a folha**

Crie `lib/ui/roster_sheet.dart`:

```dart
import 'package:flutter/material.dart';

import '../room/reverb_client.dart';
import '../room/room_session.dart';
import '../room/roster.dart';

/// A barra de presença, que é também a porta.
///
/// Sem gaveta: uma `endDrawer` precisa ou de swipe da borda — que disputa com
/// o gesto de voltar nas duas plataformas — ou de um ícone de 24 px na AppBar.
/// Esta barra já existia, é de largura inteira e já teria que virar tocável
/// para resolver o corte dos nomes. Uma afordância em vez de duas, e um alvo
/// operável de luva.
class PresenceBar extends StatelessWidget {
  const PresenceBar({super.key, required this.session, required this.me});

  final RoomSession session;
  final int me;

  @override
  Widget build(BuildContext context) => StreamBuilder<ReverbConnection>(
        stream: session.connectionState,
        initialData: session.connectionNow,
        builder: (context, connection) => StreamBuilder<RoomPresence>(
          stream: session.presence,
          initialData: session.presenceNow,
          builder: (context, presence) {
            final roster = Roster.from(
              known: session.current.members,
              present: presence.data?.members ?? const [],
              connected: connection.data == ReverbConnection.connected,
              me: me,
            );

            return _Bar(
              roster: roster,
              onTap: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (_) => RosterSheet(roster: roster),
              ),
            );
          },
        ),
      );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.roster, required this.onTap});

  final Roster roster;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;

    final names = roster.entries
        .where((e) => e.presence == PilotPresence.listening)
        .map((e) => e.isMe ? 'você' : e.displayName)
        .join(', ');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 16, right: 16),
        child: Row(
          children: [
            Icon(
              Icons.circle,
              size: 9,
              color: roster.certain ? colors.primary : colors.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                roster.certain
                    ? '${roster.listening} de ${roster.total} ouvindo'
                        '${names.isEmpty ? '' : ' · $names'}'
                    : 'Reconectando…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: small,
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: colors.outline),
          ],
        ),
      ),
    );
  }
}

/// Quem está ouvindo, em dois grupos.
class RosterSheet extends StatelessWidget {
  const RosterSheet({super.key, required this.roster});

  final Roster roster;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          Text(
            roster.certain
                ? '${roster.listening} de ${roster.total} ouvindo agora'
                : 'Reconectando',
            style: text.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            roster.certain
                // Um Android com a tela apagada cai da presença de propósito:
                // sem Foreground Service — Fase 4 — ele realmente para de
                // receber. O indicador vai estar certo quando parecer errado.
                ? 'Quem está fora não ouve a sua fala ao vivo. Um celular com '
                    'a tela apagada pode sair daqui e continuar na sala.'
                : 'Não dá para saber quem está ouvindo enquanto a sua conexão '
                    'não volta.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final entry in roster.entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                switch (entry.presence) {
                  PilotPresence.listening => Icons.hearing,
                  PilotPresence.away => Icons.hearing_disabled,
                  PilotPresence.unknown => Icons.help_outline,
                },
                color: switch (entry.presence) {
                  PilotPresence.listening => colors.primary,
                  PilotPresence.away => colors.outline,
                  PilotPresence.unknown => colors.outline,
                },
              ),
              title: Text(entry.isMe
                  ? '${entry.displayName} (você)'
                  : entry.displayName),
              trailing: Text(
                switch (entry.presence) {
                  PilotPresence.listening => 'ouvindo',
                  PilotPresence.away => 'fora',
                  PilotPresence.unknown => '',
                },
                style: TextStyle(
                  color: entry.presence == PilotPresence.listening
                      ? colors.primary
                      : colors.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: trocar a barra na tela da sala**

Em `lib/ui/room_screen.dart`, adicione `import 'roster_sheet.dart';` e troque
todo o `bottom: PreferredSize(...)` da `AppBar` por:

```dart
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: PresenceBar(session: session, me: scope.userId),
        ),
```

`scope` já é lido logo acima do `return Scaffold(` neste método.

- [ ] **Step 3: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 4: conferir com dois aparelhos**

Os dois na sala: a barra diz "2 de 2 ouvindo". Desligue o Wi-Fi de um: no outro,
a barra cai para "1 de 2" e a folha mostra o ausente como **fora**. Desligue o
Wi-Fi do aparelho que você está olhando: a barra vira "Reconectando…" e a folha
diz que não dá para saber — **e não** mostra a lista velha em verde.

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/roster_sheet.dart lib/ui/room_screen.dart && git commit -m "feat: quem está ouvindo, pela barra de presença

A barra já existia e já teria que virar tocável para resolver o corte dos
nomes; usá-la como porta é uma afordância em vez de duas, e um alvo
operável de luva. Uma gaveta precisaria de swipe da borda, que disputa
com o gesto de voltar.

O ponto da barra é o indicador de conexão: a mesma linha responde 'eu
estou conectado?' e 'quem me ouve?', que são a mesma pergunta vista das
duas pontas."
```

---

## Task 11: Meio-duplex na reprodução por toque

`playFromHistory` documenta que "respeita o meio-duplex" e chama `player.play()`
direto, sem consultar `pttHeld`.

**Files:**
- Modify: `lib/room/room_session.dart:309`
- Test: `test/room/room_session_test.dart`

- [ ] **Step 1: dar ao teste um player e um gravador que não chamam plugin**

`pressPtt()` chama `player.interrupt()` — `just_audio`, que num `flutter test`
no host não tem plugin — e `recorder.start()`, que no `_SilentRecorder` do
arquivo lança pelo `noSuchMethod`. E o `catch` do `pressPtt` **solta o PTT de
volta** antes de relançar, que é exatamente o estado que este teste precisa que
fique acionado. Sem estas duas dublês o teste falha pelo motivo errado.

Em `test/room/room_session_test.dart`, ao lado do `_SilentRecorder` que já
existe, acrescente:

```dart
/// Não toca nada. A invariante em teste é de ordem, não de som, e um teste de
/// host nunca deveria construir um player de verdade.
class _SilentPlayer extends SegmentPlayer {
  @override
  Future<void> play(String filePath) async {}

  @override
  Future<void> interrupt() async {}
}

/// Abre e fecha o PTT sem tocar no microfone.
class _OpenablePttRecorder extends PttRecorder {
  _OpenablePttRecorder({required super.segmentMax, required super.serverNow})
      : super(recorder: _SilentRecorder());

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}
```

E no `setUp`, troque as duas linhas da construção da `RoomSession`:

```dart
      recorder: _OpenablePttRecorder(
        segmentMax: budgets.segmentMax,
        serverNow: clock.now,
      ),
      player: _SilentPlayer(),
```

- [ ] **Step 2: conferir que os testes que já existiam continuam passando**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter test test/room/room_session_test.dart
```

Esperado: tudo verde. Se algum falhar aqui, **pare**: significa que ele dependia
do player de verdade, e um teste de host que depende de plugin nativo é um
problema maior que esta tarefa.

- [ ] **Step 3: escrever o teste que falha**

Acrescente, antes do fecho do `main()`:

```dart
  test('com o PTT acionado, tocar do histórico não abre uma segunda voz',
      () async {
    // A invariante é da spec, não conveniência do app: uma voz por vez, e
    // enquanto o PTT está acionado nada toca. O botão de repetir encosta no
    // PTT, então isto deixa de ser um acidente raro.
    await session.ingest(message('m-1'));
    await session.pressPtt();

    final problem = await session.playFromHistory('m-1');

    expect(problem, isNotNull);
    expect(problem, contains('PTT'));
  });
```

- [ ] **Step 4: rodar e ver falhar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter test test/room/room_session_test.dart --plain-name "com o PTT acionado"
```

Esperado: FAIL — `Expected: not null / Actual: <null>`.

- [ ] **Step 5: implementar**

Em `lib/room/room_session.dart`, dentro de `playFromHistory`, **antes** do
`if (!audioStore.has(messageId))`:

```dart
    // Meio-duplex: enquanto o PTT está acionado, nada toca. A documentação
    // desta função já prometia isto e o código não cumpria — só não aparecia
    // porque exigia dois dedos. Com o botão de repetir encostado no PTT,
    // passa a aparecer.
    if (_queue.pttHeld) {
      return 'O microfone está aberto. Solte o PTT para ouvir.';
    }
```

- [ ] **Step 6: rodar e ver passar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter test test/room
```

Esperado: todos passando, inclusive os que já existiam.

- [ ] **Step 7: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/room/room_session.dart test/room/room_session_test.dart && git commit -m "fix: tocar do histórico respeita o meio-duplex, como já dizia que fazia

A função documentava 'entra na mesma fila e respeita o meio-duplex' e
chamava player.play() direto. Só não aparecia porque exigia tocar uma
linha com um dedo segurando o PTT com o outro — com o botão de repetir
encostado no PTT, deixa de ser raro.

Uma voz por vez é invariante da spec, não conveniência do app."
```

---

## Task 12: `replay.dart` — a rajada, não o último segmento

Uma fala de 12 s são três mensagens com o mesmo `burst_id`. Repetir só a mais
nova devolveria os últimos dois segundos de uma frase.

**Files:**
- Create: `lib/history/replay.dart`
- Test: `test/history/replay_test.dart`

- [ ] **Step 1: escrever os testes que falham**

Crie `test/history/replay_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flycomm/history/database.dart';
import 'package:flycomm/history/replay.dart';

void main() {
  /// `watchRoom` devolve do mais novo para o mais velho — é o que dá o
  /// autoscroll de graça na tela, com `reverse: true`.
  LocalMessage segment(
    String id, {
    required String burst,
    required int index,
    required DateTime recordedAt,
    MessageDirection direction = MessageDirection.incoming,
    String? audioPath = '/tmp/a.wav',
  }) =>
      LocalMessage(
        id: id,
        roomId: 255,
        burstId: burst,
        segmentIndex: index,
        authorId: 510,
        authorName: 'Marina',
        durationMs: 5000,
        origin: 'app',
        format: 'wav-pcm16-16k',
        capturedAt: recordedAt,
        createdAt: recordedAt,
        direction: direction,
        state: MessageState.received,
        played: false,
        audioPath: audioPath,
        recordedAt: recordedAt,
      );

  final base = DateTime.utc(2026, 9, 14, 12);

  test('devolve os três segmentos da rajada, em ordem crescente', () {
    final rows = [
      segment('c', burst: 'b-1', index: 2, recordedAt: base.add(const Duration(seconds: 10))),
      segment('b', burst: 'b-1', index: 1, recordedAt: base.add(const Duration(seconds: 5))),
      segment('a', burst: 'b-1', index: 0, recordedAt: base),
    ];

    expect(lastIncomingBurst(rows).map((m) => m.id), ['a', 'b', 'c']);
  });

  test('pega a rajada mais nova, não a anterior', () {
    final rows = [
      segment('nova', burst: 'b-2', index: 0, recordedAt: base.add(const Duration(minutes: 1))),
      segment('velha', burst: 'b-1', index: 0, recordedAt: base),
    ];

    expect(lastIncomingBurst(rows).map((m) => m.id), ['nova']);
  });

  test('ignora a própria fala do piloto', () {
    // "Diga de novo" é sobre o que o outro disse. A própria fala o piloto
    // acabou de dizer.
    final rows = [
      segment('minha',
          burst: 'b-2',
          index: 0,
          recordedAt: base.add(const Duration(minutes: 1)),
          direction: MessageDirection.outgoing),
      segment('dele', burst: 'b-1', index: 0, recordedAt: base),
    ];

    expect(lastIncomingBurst(rows).map((m) => m.id), ['dele']);
  });

  test('ignora segmento sem áudio no aparelho', () {
    // O blob vence no servidor em minutos. Um segmento que não baixou a tempo
    // não toca, e a rajada toca sem ele: parcial é melhor que nada, e a linha
    // do histórico já mostra que falta.
    final rows = [
      segment('b', burst: 'b-1', index: 1, recordedAt: base.add(const Duration(seconds: 5))),
      segment('a', burst: 'b-1', index: 0, recordedAt: base, audioPath: null),
    ];

    expect(lastIncomingBurst(rows).map((m) => m.id), ['b']);
  });

  test('sem nada recebido, devolve vazio', () {
    expect(lastIncomingBurst(const []), isEmpty);
  });
}
```

- [ ] **Step 2: rodar e ver falhar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter test test/history/replay_test.dart
```

Esperado: falha de compilação — `Target of URI doesn't exist: 'package:flycomm/history/replay.dart'`.

- [ ] **Step 3: implementar**

Crie `lib/history/replay.dart`:

```dart
import 'database.dart';

/// Os segmentos da rajada recebida mais nova que dá para tocar, em ordem.
///
/// [newestFirst] é o que `HistoryRepository.watchRoom` entrega: do mais novo
/// para o mais velho.
///
/// **A rajada, e não o último segmento.** Uma fala de 12 s são três mensagens
/// com o mesmo `burst_id` e índices 0, 1 e 2. Repetir só a mais nova devolveria
/// os últimos dois segundos de uma frase — o suficiente para o botão parecer
/// funcionar e não entregar a informação, que é o pior dos dois.
///
/// Segmento sem `audioPath` fica de fora e a rajada toca sem ele: o blob vence
/// no servidor em minutos, parcial é melhor que nada, e a linha do histórico já
/// mostra que falta.
List<LocalMessage> lastIncomingBurst(List<LocalMessage> newestFirst) {
  final playable = newestFirst.where((message) =>
      message.direction == MessageDirection.incoming &&
      message.audioPath != null);

  if (playable.isEmpty) return const [];

  final burstId = playable.first.burstId;

  return playable.where((message) => message.burstId == burstId).toList()
    ..sort((a, b) => a.segmentIndex.compareTo(b.segmentIndex));
}
```

- [ ] **Step 4: rodar e ver passar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter test test/history/replay_test.dart
```

Esperado: `+5: All tests passed!`

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/history/replay.dart test/history/replay_test.dart && git commit -m "feat: achar a rajada a repetir, em função pura

Uma fala de 12 s são três mensagens com o mesmo burst_id. Repetir só a
mais nova devolveria os últimos dois segundos de uma frase — o bastante
para o botão parecer funcionar e não entregar a informação."
```

---

## Task 13: Repetir a última

**Files:**
- Modify: `lib/room/room_session.dart`
- Modify: `lib/ui/room_screen.dart`

- [ ] **Step 1: a repetição na sessão**

Em `lib/room/room_session.dart`, logo depois de `playFromHistory`:

```dart
  /// Toca uma rajada inteira, em ordem, e **para no meio se o PTT for
  /// acionado**: o meio-duplex vale para a repetição como vale para a fila.
  ///
  /// Parar não é erro e não devolve razão — o piloto interrompeu de propósito,
  /// porque quis falar.
  Future<String?> replayBurst(List<String> messageIds) async {
    for (final id in messageIds) {
      if (_queue.pttHeld) return null;

      final problem = await playFromHistory(id);
      if (problem != null) return problem;
    }

    return null;
  }
```

- [ ] **Step 2: o botão, ao lado do PTT**

Em `lib/ui/room_screen.dart`, adicione o import:

```dart
import '../history/replay.dart';
```

Adicione o método a `_RoomScreenState`:

```dart
  /// "Diga de novo" é a afordância mais antiga do rádio, e até aqui ela exigia
  /// achar a linha certa numa lista que cresce o voo inteiro.
  Future<void> _replayLast(RoomSession session, List<LocalMessage> rows) async {
    final burst = lastIncomingBurst(rows);

    if (burst.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Ninguém falou ainda — não há o que repetir.'),
      ));
      return;
    }

    final problem =
        await session.replayBurst(burst.map((m) => m.id).toList());

    if (problem == null || !mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(problem)));
  }
```

- [ ] **Step 3: pendurar o botão na lista de mensagens**

O botão precisa das linhas, que só existem dentro do `StreamBuilder`. Guarde a
última lista num campo de `_RoomScreenState`:

```dart
  List<LocalMessage> _rows = const [];
```

Dentro do `builder:` do `StreamBuilder<List<LocalMessage>>`, logo depois de
`final rows = snapshot.data ?? const <LocalMessage>[];`:

```dart
                // Atribuição simples durante o build, sem setState: o botão de
                // repetir precisa das linhas, que só existem aqui dentro, e
                // guardar a última é mais barato que uma segunda assinatura do
                // mesmo stream.
                _rows = rows;
```

E troque o `Padding` do `PttButton` no fim do `Column` por:

```dart
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: PttButton(
                    enabled: _micGranted,
                    onPress: session.pressPtt,
                    onRelease: session.releasePtt,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 140,
                  width: 84,
                  child: OutlinedButton(
                    onPressed: () => _replayLast(session, _rows),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.replay, size: 30),
                        SizedBox(height: 6),
                        Text('Repetir', textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
```

- [ ] **Step 4: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 5: conferir com dois aparelhos**

No aparelho A, segure o PTT por 12 s e fale contando "um, dois, três…". Em B,
toque em Repetir: os **três** segmentos tocam em ordem, sem buraco. Toque em
Repetir e, no meio, segure o PTT: a repetição para.

- [ ] **Step 6: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/room/room_session.dart lib/ui/room_screen.dart && git commit -m "feat: repetir a última fala

'Diga de novo' é a afordância mais antiga do rádio, e até aqui exigia
achar a linha certa numa lista que cresce o voo inteiro.

A rajada inteira, em ordem — e parando no meio se o PTT for acionado: o
meio-duplex vale para a repetição como vale para a fila."
```

---

## Task 14: Háptico no PTT

O botão da tela não devolve nada ao tato, e é operado em voo, de luva, com o
piloto olhando para fora.

**Files:**
- Modify: `lib/ui/ptt_button.dart`

- [ ] **Step 1: adicionar**

Em `lib/ui/ptt_button.dart`, adicione o import:

```dart
import 'package:flutter/services.dart';
```

E nos dois métodos:

```dart
  Future<void> _press() async {
    if (!widget.enabled || _held) return;
    // Seguro porque `pressPtt` toca o aviso de "pode falar" **até o fim**
    // antes de abrir a captura: o motor de vibração para antes de o microfone
    // existir, e não entra na gravação.
    await HapticFeedback.heavyImpact();
    setState(() => _held = true);
    await widget.onPress();
  }

  Future<void> _release() async {
    if (!_held) return;
    await HapticFeedback.lightImpact();
    setState(() => _held = false);
    await widget.onRelease();
  }
```

- [ ] **Step 2: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 3: conferir no aparelho**

Segure o PTT e fale. Esperado: um toque forte ao apertar, um leve ao soltar, e
**nenhum ruído de motor no começo da gravação** — ouça a própria fala no
histórico do outro aparelho.

- [ ] **Step 4: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/ptt_button.dart && git commit -m "feat: o PTT da tela responde ao tato

Ele é operado em voo, de luva, com o piloto olhando para fora, e não
devolvia nada.

Seguro porque pressPtt toca o aviso de 'pode falar' até o fim antes de
abrir a captura: o motor para antes de o microfone existir."
```

---

## Task 15: A permissão de microfone ganha saída — e revalidação

O aviso é um texto sem ação. E o piloto que concede a permissão nos ajustes
volta para o app e encontra a mesma frase dizendo que ele só ouve.

**Files:**
- Modify: `lib/ui/room_screen.dart`

- [ ] **Step 1: revalidar ao voltar do segundo plano**

Faça `_RoomScreenState` observar o ciclo de vida. Troque a declaração da classe:

```dart
class _RoomScreenState extends State<RoomScreen> with WidgetsBindingObserver {
```

Em `didChangeDependencies`, depois de `if (_session == null) _open();`, não mude
nada; adicione em vez disso os dois métodos:

```dart
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// A metade que importa do botão de ajustes.
  ///
  /// Sem isto, o piloto concede a permissão, volta, e encontra a mesma frase
  /// dizendo que ele só ouve. Ele não tem como saber que o texto é que está
  /// velho.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _micGranted) return;

    Permission.microphone.status.then((status) {
      if (mounted && status.isGranted) setState(() => _micGranted = true);
    });
  }
```

E em `dispose`, como **primeira** linha:

```dart
    WidgetsBinding.instance.removeObserver(this);
```

- [ ] **Step 2: o aviso ganha botão**

Troque o bloco `if (!_micGranted)` do `Column` por:

```dart
          if (!_micGranted)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Sem permissão de microfone: você só ouve.'),
                  ),
                  TextButton(
                    onPressed: openAppSettings,
                    child: const Text('Ajustes'),
                  ),
                ],
              ),
            ),
```

`openAppSettings` vem do `permission_handler`, já importado neste arquivo.

- [ ] **Step 3: analisar**

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze
```

Esperado: **as mesmas 10 issues de antes, nenhuma nova**. Veja a nota de
baseline em "Antes de começar" — não conserte lint fora do escopo desta tarefa.

- [ ] **Step 4: conferir no aparelho**

Negue o microfone. Entre na sala: o aviso aparece com "Ajustes". Toque, conceda
a permissão nos ajustes do sistema, volte ao app. Esperado: o aviso some e o
PTT fica habilitado, **sem reiniciar**.

- [ ] **Step 5: commit**

```bash
cd /Users/rodrigo/dev/flycomm-app && git add lib/ui/room_screen.dart && git commit -m "fix: negar o microfone deixa de ser beco sem saída

O aviso era texto sem ação, e quem concedia a permissão nos ajustes
voltava para a mesma frase dizendo que só ouve — sem como saber que o
texto é que estava velho."
```

---

## Verificação final

Rode a suíte inteira de unidade:

```bash
cd /Users/rodrigo/dev/flycomm-app && flutter analyze && flutter test test/room test/audio test/history test/ui
```

E compile em release e instale **por cima**, nunca com `flutter install` — ele
desinstala antes, e no iOS isso leva junto o histórico, que é local e
permanente:

```bash
flutter build apk --release --dart-define=FLYCOMM_HTTP=http://SEU_IP:8000 --dart-define=FLYCOMM_WS_HOST=SEU_IP --dart-define=FLYCOMM_WS_PORT=8080 --dart-define=FLYCOMM_WS_KEY=flycomm-local-key
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Os critérios da §9 da spec, com dois aparelhos contra o servidor real:

- [ ] Trocar o nome na configuração de A: o nome novo aparece na presença e no
      histórico de B, sem reinstalar
- [ ] A, sem sala nenhuma, cria uma sala, lê o código na tela dela, e B entra
      por esse código
- [ ] A sai da sala: some da presença de B, e o histórico daquela sala continua
      no aparelho de A
- [ ] Wi-Fi desligado em B: a barra de A **não** mostra B como ouvindo
- [ ] Wi-Fi desligado em A: a folha de A diz que não dá para saber, e **não**
      mostra a lista velha em verde
- [ ] Um terceiro aparelho entra na sala: aparece na folha de A e de B sem que
      eles recarreguem
- [ ] Fala de 12 s em A: Repetir em B toca os três segmentos em ordem, sem
      buraco
- [ ] Segurar o PTT durante a repetição a interrompe, e não produz duas vozes
- [ ] Negar o microfone, concedê-lo nos ajustes e voltar: o aviso some sem
      reiniciar
