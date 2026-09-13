# Specs — espelho, não original

Os arquivos deste diretório são **cópias verbatim** das specs que vivem em
`flycomm/docs/superpowers/specs/`. Aquele repositório é a fonte canônica.

Por que existem cópias aqui: os repositórios são independentes, e um agente
trabalhando neste repo precisa da spec em mãos, sem depender de um checkout
vizinho.

Por que a fonte é lá: a spec descreve o **contrato entre o servidor e o app**
— endpoints, payload dos eventos, nomes dos campos, orçamentos de tempo. Se
cada repo editar a sua cópia, os dois lados divergem e a divergência só
aparece no primeiro teste de integração.

**Regra:** nunca edite estes arquivos. Mudança de contrato é commit no
`flycomm`, seguido de `cp` para os dois repos. Como as cópias são verbatim,
`diff` contra a origem detecta drift.
