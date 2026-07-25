# PR3 — redução de escopo (jornadas / UI)

Entregável da **correção 6**. Conclusão: **não construir sistema novo de
divulgação progressiva.** O que a Fase 2.1 pretendia criar já existe em
`linux/ui_native/catalog.py` e está coerente.

## Auditoria do que já existe

`catalog.py` classifica toda action em duas dimensões, resolvidas no
construtor `_a()` (`linux/ui_native/catalog.py:69`):

- `risk` — `normal` · `elevated` · `high`. Inferido do `badge`
  (`Alto risco`/`Resgate` → `high`) e da flag `elevated`.
- `visibility` — `primary` · `standard` · `advanced`. Inferido de `risk`
  (`elevated`/`high` → `advanced`), com override explícito quando o caso pede.

Números da auditoria (432 actions):

| Dimensão | Distribuição |
|---|---|
| `visibility` | 279 `standard` · 134 `advanced` · 19 `primary` |
| `risk` | 365 `normal` · 53 `elevated` · 14 `high` |

### Achado que contraria a premissa da correção 6

A correção pedia: *"audite todas as actions com `visibility` vazia/nula;
classifique `standard` vs `advanced` por risco real"*.

**Nenhuma action tem `visibility` vazia ou nula.** O default de `_a()` torna
esse estado inalcançável — uma action sem `visibility` declarada recebe a
inferida, nunca string vazia. Não há nada para classificar.

O que a auditoria encontrou, em vez disso:

1. **As 14 actions de risco alto estão todas em `advanced`.** Incluindo as
   sete destrutivas (`system.installation.converge`, `server.homelab.restore`,
   `server.casaos.install`, `boot.efi`, `boot.emergency`,
   `boot.grubfm.install`, `host.wipe`). Zero vazamentos.
2. **15 actions `elevated` ficam em `standard` — de propósito.** São
   `capability.plan.*` (previews, badge "Plano seguro") e `capability.apply`,
   que só executa com `--plan-id` + token de confirmação gerados por um plano
   anterior. Esconder um fluxo já protegido por token adicionaria fricção sem
   adicionar segurança.
3. **50 actions somente-leitura estão em `advanced`.** São variantes `.status`
   e `.plan` de CLI que o próprio código descreve como não promovidas ao fluxo
   principal. Reduz ruído; não esconde nada perigoso.

Conclusão: o modelo está certo. O que faltava não era classificação — era
**trava de regressão**. `tests/test_catalog_visibility.py` fixa as invariantes:
vocabulário fechado, destrutivo nunca em `standard`, risco alto sempre em
`advanced`, toda mutação com preview não-destrutivo, e a própria inferência.

## Escopo do PR3, reduzido

**Fora** (não fazer):

- ~~Novo sistema de divulgação progressiva na Fase 2.1.~~ Já existe.
- ~~Reclassificar actions em massa.~~ A auditoria não achou erro de
  classificação; mexer só introduziria regressão.
- ~~Novo campo/enum de "nível de usuário".~~ `visibility` já é isso.

**Dentro** (fazer, reaproveitando a infra existente):

1. **Copy e curadoria em PT** — títulos e descrições das actions promovidas,
   revisando o que hoje é tradução literal do verbo de CLI.
2. **Busca global** — indexar `title` + `description` + `keywords`. O campo
   `keywords` já existe em `ActionSpec` e já é populado; falta a UI de busca.
   As actions novas de Manutenção (PR2) já chegam com keywords em PT.
3. **Agrupamento do dashboard** — melhorar `SIDEBAR_GROUPS` e
   `DASHBOARD_QUICK`/`DASHBOARD_TOOLS`, que hoje são listas curadas à mão.

Custo estimado do PR3 depois da redução: uma passada de copy + uma barra de
busca sobre um índice que já existe. Sem migração de dados, sem novo modelo,
sem risco de regressão em ação destrutiva.

## Verificação

```bash
pytest tests/test_catalog_visibility.py -q
```
