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

Repositório recém-criado. O `flutter create` ainda não foi feito — é o primeiro
passo do plano de implementação, e depende do backend estar de pé.
