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

Fase 2 implementada e rodando em iPhone e simulador contra o backend real.
Quatro dos seis critérios de conclusão da seção 8 da spec estão cumpridos — ver
[docs/fase-2-aceitacao.md](docs/fase-2-aceitacao.md) para o que foi medido e o
que falta.

O [plano de implementação](docs/superpowers/plans/2026-09-13-fase-2-app-flutter.md)
é o documento mais útil para entender o porquê de cada decisão: ele carrega o
contrato verificado contra o servidor real, as divergências encontradas e as
armadilhas que só aparecem no aparelho.

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

## Nota sobre credenciais

Os valores que aparecem no plano e nos testes (`demo-device-*`, `demo-secret-*`,
`flycomm-local-key`, IPs `192.168.*`) são de bancada: dispositivos semeados pelo
`docker compose` local e a chave padrão do Reverb em desenvolvimento. Não dão
acesso a nada. Se um dia houver ambiente publicado, ele precisa de chave própria
— reaproveitar estes valores seria transformar exemplo em segredo de verdade.
