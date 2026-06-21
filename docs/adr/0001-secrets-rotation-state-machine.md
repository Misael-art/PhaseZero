# ADR 0001 — State Machine para Rotação Automática de Secrets

- **Status:** Proposed
- **Data:** 2026-05-14
- **Autor:** PhaseZero Bootstrap
- **Escopo:** TASK-002 do `AGENT_EXECUTION_PLAN.md`
- **Substitui:** —
- **Substituído por:** —
- **Tasks dependentes:** TASK-003 (worker), TASK-004 (scheduler), TASK-005 (eventos), TASK-006 (testes), TASK-006a (isolamento de commits)

## Contexto

O manifesto `bootstrap-secrets.json` (v2) já suporta múltiplas credenciais por provider, com `activeCredential`, `rotationOrder`, e validadores dedicados (`openai`, `anthropic`, `google`, `openrouter`, `github`, `moonshot`, `deepseek`). A rotação atual é **one-shot e manual**:

- `Move-BootstrapSecretsToNextCredential` valida a fila inteira de uma vez e troca para a primeira `passed`.
- Não há fila programática (`queued → ...`).
- Não há timeout exposto, retry, backoff, lock cross-process ou log estruturado de evento.
- Mudanças ao manifest **não passam** por `Register-BootstrapChange`, então o rollback ignora rotações.

Para suportar rotação agendada (Task Scheduler do Windows ou disparo CLI `-RotateSecrets`), precisamos de uma máquina de estados explícita por item da fila, com transições determinísticas, política clara de falha, e produção de eventos auditáveis.

## Decisão

### Estados

```
   ┌─────────┐  enfileirar    ┌────────────┐  validador OK     ┌────────────┐
   │ queued  ├───────────────▶│ validating ├──────────────────▶│ activating │
   └────┬────┘                └─────┬──────┘                   └──────┬─────┘
        │                           │  validador FAIL                  │
        │                           │  (esgotou retries)               │ ativação OK
        │                           ▼                                  ▼
        │                      ┌────────┐                       ┌─────────────┐
        │     timeout total    │ failed │  ◀── ativação FAIL ── │broadcasting │
        └─────────────────────▶│        │                       └──────┬──────┘
                               └────────┘                              │
                                                                       │ broadcast OK (≥ minBroadcastSuccess)
                                                                       ▼
                                                                  ┌────────┐
                                                                  │settled │
                                                                  └────────┘
```

| Estado | Significado | Transições válidas |
|---|---|---|
| `queued` | Item adicionado à fila, aguardando worker | → `validating` (worker pega) ou `failed` (timeout global) |
| `validating` | Worker chamou `Test-BootstrapSecretsProviderCredential` | → `activating` (state=passed) / `validating` (retry) / `failed` (retries esgotados ou timeout) |
| `activating` | Marca credencial como `activeCredential` no manifest | → `broadcasting` (sucesso) / `failed` (manifest write falhou) |
| `broadcasting` | Roda `Ensure-BootstrapSecrets` para propagar a todos os consumers | → `settled` (≥ `minBroadcastSuccess`) / `failed` (abaixo do limiar) |
| `settled` | Sucesso — credencial ativa, consumers atualizados | terminal |
| `failed` | Falha em qualquer etapa — credencial anterior mantida | terminal |

**Invariante crítica:** sair de `failed` exige novo item na fila. O worker **nunca** sobrescreve `activeCredential` em falha — o estado anterior é preservado.

### Item da fila (forma serializada)

Armazenado em `bootstrap-secrets.json` sob `providers.<name>.rotationQueue` (array). Cada item:

```json
{
  "id": "rot-openai-2026-05-14T12-30-00Z-a1b2",
  "provider": "openai",
  "targetCredentialId": "openai-backup-01",
  "trigger": "scheduled | manual | cli",
  "state": "queued",
  "attempts": 0,
  "maxAttempts": 3,
  "timeoutSecondsPerValidator": 15,
  "timeoutSecondsTotal": 120,
  "createdAt": "2026-05-14T12:30:00Z",
  "lastTransitionAt": "2026-05-14T12:30:00Z",
  "previousActiveCredentialId": "openai-primary-01",
  "lastError": "",
  "events": [
    { "at": "2026-05-14T12:30:00Z", "from": "", "to": "queued", "message": "" }
  ]
}
```

`targetCredentialId` opcional:
- ausente → política "próxima válida na `rotationOrder`" (compatível com `Move-BootstrapSecretsToNextCredential`).
- presente → tenta especificamente essa credencial; se falhar, item vai a `failed` (não cai para próxima — usuário pediu uma específica).

### Política de retry e backoff

- **Por item:** até `maxAttempts` (default 3).
- **Backoff:** exponencial com jitter — `delaySeconds = min(60, 2^attempt + random(0, 1.5))`.
- **Erros retryáveis:** `5xx`, timeout de conexão, `429`. Erros `401/403` são **terminais** imediatamente (credencial inválida não vai melhorar com retry).
- **Worker decide:** classificação fica em helper `Get-BootstrapSecretsValidationFailureCategory` (a criar em TASK-003).

### Política de timeout

- **Por validador (HTTP):** `timeoutSecondsPerValidator` default `15s`. Exposto como parâmetro de `Test-BootstrapSecretsProviderCredential`.
- **Por item:** `timeoutSecondsTotal` default `120s` cobre todas as tentativas + backoff.
- **Worker (`Invoke-BootstrapSecretRotation`):** `-MaxItems` e `-TimeoutSeconds` globais. Item ainda `queued`/`validating` quando o tempo global esgota → permanece `queued` (próxima execução continua de onde parou). Item em `activating`/`broadcasting` **completa a transição atual** antes de devolver controle (evita estado parcial no disco).

### Política de broadcast

- `broadcasting` chama `Ensure-BootstrapSecrets` (existente). Resultado é um sumário com flags por consumer.
- `minBroadcastSuccess` default `1` — basta um consumer aceitar para considerar `settled`. Falha total (zero consumers) → `failed` e **rollback do `activeCredential`** ao `previousActiveCredentialId`.
- Falha parcial → `settled` + evento `partial-broadcast` listando consumers que falharam (consumível pela UI).

### Concorrência

- **Lock baseado em arquivo:** `.bootstrap-tools/bootstrap-secrets.json.lock` criado com `[System.IO.FileStream]` modo `FileShare::None`.
- Tentativa adquire lock com timeout de `5s`. Se falhar → erro `RotationConcurrencyError`, worker aborta limpo (não modifica estado).
- Lock cobre **toda** a transição de um item (queued→settled|failed). Liberado em `finally`.
- Save do manifest **sempre** dentro do lock; leitura inicial também (`Get-BootstrapSecretsData` é a-tômica? confirmar em TASK-003; se não, envolver).

### Rollback (`Register-BootstrapChange`)

Cada transição que mutar disco registra mudança com categoria `secrets-rotation` e payload mínimo:

```
{
  "category": "secrets-rotation",
  "provider": "openai",
  "from": "openai-primary-01",
  "to": "openai-backup-01",
  "rotationId": "rot-openai-..."
}
```

`Invoke-BootstrapRollback` reverte aplicando `previousActiveCredentialId` e rodando `Ensure-BootstrapSecrets` novamente. Lista exata de helpers de rollback fica em TASK-013 (escopo lint), mas o registrar é obrigatório a partir de TASK-003.

### Trigger temporal (TASK-004)

- Flag CLI `-RotateSecrets` enfileira **todos os providers cuja credencial ativa tem `validation.state in (failed, unknown)` há mais de `staleHours`** (default 24h) e dispara worker.
- Componente `bootstrap-secrets` ganha opção opt-in em `Get-BootstrapUiContract` (campo `secretsRotation.schedule`):
  - `none` (default) — sem trigger.
  - `daily` — Task Scheduler do Windows com gatilho diário 03:17 local.
  - `weekly` — domingo 03:17 local.
- Tarefa agendada registra-se via `Register-BootstrapChange` (categoria `scheduled-task`) para rollback.

### Eventos estruturados (TASK-005)

- Arquivo: `.bootstrap-tools/rotation-events.jsonl` (UTF-8, sem BOM, line-delimited).
- Cada linha = um evento (transição de estado, retry, partial-broadcast, falha de lock).
- Rotação simples: cap em 1000 linhas — ao ultrapassar, descarta as 250 mais antigas (rewrite atômico via `.tmp` + `Move-Item -Force`).
- Forma do evento:

```json
{"at":"...","rotationId":"...","provider":"openai","from":"validating","to":"activating","ok":true,"message":"","attempt":1}
```

- UI lê últimas N entradas (não streaming) para o painel — implementação fica em fase futura, TASK-005 apenas garante o produtor.

### Mascaramento

- Nenhum campo do evento contém o segredo bruto. `previousActiveCredentialId` e `targetCredentialId` referenciam IDs (já documentados publicamente).
- Logs (`Write-Log`) durante validação seguem regra existente (provedor sabe mascarar; convenção do projeto).

## Consequências

**Positivas:**
- Rotação fica auditável (eventos JSONL + change manifest).
- Failure isolada (1 provider falhando não bloqueia outros — fila por item).
- Retry inteligente reduz falsos negativos por flaky network.
- Compatibilidade com `Move-BootstrapSecretsToNextCredential` mantida — função vira *legacy thin wrapper* sobre o worker novo.

**Negativas:**
- `bootstrap-secrets.json` ganha campo `rotationQueue`. Manifestos v2 existentes precisam migração (no-op: campo ausente vira `[]`). Não bump de schema major.
- Lock por arquivo é frágil em FS remoto (SMB), mas o caso de uso é local — aceitável.

**Neutras:**
- Worker é síncrono. Paralelismo entre providers (otimização futura) fica como ADR posterior.

## Alternativas consideradas

1. **Sem state machine explícita — apenas estender `Move-...ToNextCredential`.** Rejeitada: mistura validação + ativação + broadcast num único ponto, impossibilita retry direcionado e eventos por transição.
2. **Fila em arquivo separado (`rotation-queue.json`).** Rejeitada: dois pontos de verdade. Manter dentro do manifest preserva atomicidade (um único write cobre estado de credenciais + estado de rotação).
3. **Lock baseado em mutex Windows nomeado.** Rejeitada: complexidade extra sem benefício (worker é local single-process; cross-process raro mas precisa funcionar — arquivo-lock cobre).
4. **Estados separados `activated` e `broadcast`.** Mantidos como `activating` e `broadcasting`. Verbos no gerúndio indicam "em progresso", reforçando que `settled` é o único sucesso final.

## Plano de adoção

1. **TASK-003** implementa o worker e as funções puras (`Get-BootstrapSecretRotationQueue`, `Add-BootstrapSecretRotationItem`, `Invoke-BootstrapSecretRotationItem`, `Invoke-BootstrapSecretRotation`). `Move-BootstrapSecretsToNextCredential` passa a delegar.
2. **TASK-004** adiciona flag `-RotateSecrets` + opção de schedule no UI Contract + criação de Task Scheduler.
3. **TASK-005** instrumenta eventos JSONL.
4. **TASK-006** valida happy path, falha de validação, timeout, retry, partial-broadcast, concorrência (2 workers simultâneos), preservação de credencial em falha.

## Checklist de aceite (revisão manual obrigatória antes de aprovar este ADR)

- [x] Diagrama ASCII presente.
- [x] Todos os 6 estados listados com transições válidas explícitas.
- [x] Política de retry (count, backoff, erros retryáveis vs terminais) definida.
- [x] Política de timeout (por-validador, por-item, global) definida.
- [x] Política de concorrência (lock por arquivo, timeout 5s) definida.
- [x] Forma serializada do item da fila com exemplo JSON.
- [x] Mascaramento abordado (nada de secret raw).
- [x] Compatibilidade com `Move-BootstrapSecretsToNextCredential` declarada.
- [x] Rollback via `Register-BootstrapChange` especificado.
- [x] Alternativas registradas com motivo da rejeição.

---

**Fim do ADR.** Atualizações exigem novo ADR (`0002-...`) referenciando este.
