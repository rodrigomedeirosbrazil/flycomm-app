# flycomm-app

App Flutter da sala de pilotos. Leia
[docs/specs/2026-09-13-fase-2-sala-e-backend-design.md](docs/specs/2026-09-13-fase-2-sala-e-backend-design.md)
antes de qualquer coisa — ela define o escopo e o contrato.

## As specs são espelho, não original

`docs/specs/` são cópias verbatim de `flycomm/docs/superpowers/specs/`.
**Nunca edite esses arquivos aqui.** Mudança de contrato (endpoint, payload de
evento, nome de campo, orçamento de tempo) é commit no `flycomm` e depois `cp`
para os dois repos.

Se durante a implementação você concluir que o contrato da spec está errado,
**pare e avise**, não ajuste localmente nem contorne no cliente.

## Invariantes que é fácil violar sem perceber

- **Uma voz por vez.** A fila de reprodução é FIFO estrito, nunca sobreposta.
  Enquanto o PTT está acionado, nada toca (meio-duplex).
- **Áudio tem prazo.** Item mais velho que `playback_deadline` sai da fila
  **sem tocar** e vira "atrasada" no histórico — ouvível por toque, nunca
  automaticamente. Uma fila que só cresce é bug, não backlog.
- **Frescor é contra o relógio do servidor.** Calcule o desvio a partir da
  resposta HTTP e aplique. Nunca compare com o relógio local direto.
- **Os orçamentos vêm de `GET /config`**, não de constantes no código.
- **Não existe fila de saída persistente.** O upload tenta dentro da janela de
  validade e desiste; a mensagem fica como **não entregue**, e o piloto precisa
  ver isso — é a informação de que ninguém o ouviu.
- **Segmento de 5 s corta o metadado, nunca o áudio.** Ao fechar um segmento, a
  captura não para.
- **Grava PCM uma vez.** A captura é PCM 16 kHz em stream, acumulada em
  segmento. Não grave direto em formato comprimido: a Fase 3 deriva ADPCM 8 kHz
  do mesmo PCM, e gravar comprimido obrigaria a reescrever a camada de áudio.
- **O histórico é 100% local e permanente.** O servidor é transporte, não
  arquivo — não busque histórico antigo lá, ele não existe.

## Módulos

Da spec: `audio/`, `room/`, `history/`, `ui/`. Os módulos `ble/`, `bridge/` e
`background/` são das Fases 3 e 4 — não crie diretórios vazios para eles.

## Dependência do backend

O app se desenvolve contra o `flycomm-server` rodando de verdade
(`docker compose up` com seed), não contra mocks.
