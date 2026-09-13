# Fase 2 — aceitação (seção 8 da spec)

Data: 2026-09-13 · Backend: `192.168.15.112:8000` (Reverb em `:8080`)

Dispositivos:

- **A** — iPhone de Rodrigo, iOS 26.6.2, build release assinado (`br.com.medeirostec.flycomm`)
- **B** — Simulador iPhone 17 Pro, iOS 26.5, build debug

Sala: **Voo de domingo** (`FLY-TEST`, id 255), 145.550 MHz.

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

## 2. Fala de 12 s vira três mensagens — **pendente**

A fala testada teve 2,6 s e virou um segmento só, o que é o comportamento correto
para essa duração, mas não exercita o corte. Falta segurar o PTT por 12 s.

## 3. Modo avião em B por 20 s — **pendente**

Observação lateral já obtida: ao entrar na sala às 15:20, os três segmentos publicados
às 15:11 **não tocaram**. Passaram do `playback_deadline` (30 s) e os blobs já tinham
vencido (`blob_ttl` de 5 min). Áudio velho não toca sozinho — a invariante da seção 2.1
vale, ainda que por um caminho diferente do que o critério 3 pede.

## 4. Wi-Fi desligado em A — **pendente**

## 5. Mudança de frequência — **pendente**

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
