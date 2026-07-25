# linux/emulation/library — biblioteca de jogos unificada

Implementa o milestone 1 da spec
[`docs/superpowers/specs/2026-07-11-unified-game-library-kde-experience-design.md`](../../../docs/superpowers/specs/2026-07-11-unified-game-library-kde-experience-design.md):
fluxo `Origem → Análise → Plano → Execução → Validação` com registry
declarativo, consumido por CLI (e futuramente pela UI nativa).

## CLI

```text
pz emulation library scan  --scope library|directory|files [--input PATH]... --json
pz emulation library plan  --scan-id ID --json
pz emulation library apply --plan-id ID --confirm TOKEN [--dry-run] --json
pz emulation library verify   --operation-id ID --json
pz emulation library rollback --operation-id ID --json
```

Todos os comandos emitem envelopes versionados (`schema: pz.emulation.library/v1`).
A UI nunca interpreta stdout humano.

## Módulos

| Módulo | Papel |
|---|---|
| `registry.py` | `SystemAdapter` por sistema público (nome, aliases, destinos, papel de archive, transformação via decision table do romopt) |
| `scan.py` | Scan read-only; estados `ready` / `action` / `blocked` / `unknown`; recusa symlinks |
| `plan.py` | Plano com blockers, espaço estimado, `confirmToken` |
| `apply.py` | Execução (install Vita3K), verify e rollback |
| `vita.py` | Adapter Vita3K: classificação de ZIP/VPK, detecção do emulador, instalação atômica em `ux0/app/<TITLE_ID>` |
| `safezip.py` | Probe de ZIP sem extração: traversal, symlink, limites de tamanho/entradas/razão de expansão |
| `sfo.py` | Parser/builder de `param.sfo` (PSF) |
| `state.py` | Registros `scan-*`/`plan-*`/`op-*` em `$XDG_STATE_HOME/phasezero/emulation-library` com modo `0600` |

## Invariantes

- scan nunca muta disco (`readOnly: true` no envelope);
- origem preservada por padrão; rollback remove somente diretórios criados
  pela operação, e somente sob `ux0/app`;
- staging no mesmo filesystem do destino, publicação por `rename` atômico;
- hashes sha256 por arquivo no manifest da operação;
- apply real exige `confirmToken` do plano;
- Vitamin/MaiDump bloqueia com motivo específico, nunca erro genérico;
- sistema reconhecido e já compatível retorna `ready`, nunca "unsupported";
- sistema desconhecido é preservado com `unknown`.

## Env overrides (testes/hosts atípicos)

- `PZ_LIBRARY_STATE_DIR` — diretório de estado;
- `PZ_EMULATION_ROOT` — raiz da biblioteca (default `~/Emulation`);
- `PZ_VITA3K_BINARY` / `PZ_VITA3K_PREF_PATH` / `PZ_APPLICATIONS_DIR` — detecção Vita3K.

## Limites desta rodada (fases seguintes da spec)

- ações `convert` são planejadas mas delegadas ao alias `rom-optimize`;
- extração de archives que embrulham imagens de disco ainda não é executada;
- launch probe reportado como `skipped` (sem sessão gráfica garantida);
- atualização de frontends (ES-DE/SRM/LaunchBox) pós-instalação fica na Fase B/C;
- UI nativa (quatro jornadas) e menu KDE unificado ficam nas Fases C/D.
