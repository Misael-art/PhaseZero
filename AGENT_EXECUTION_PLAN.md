# Plano de Execução PhaseZero — Operável por Agentes IA

> Documento vivo. Atualize **Estado de Execução** e **Log de Decisões** a cada sessão.
> Não delete tarefas concluídas — mova-as para `## Histórico`.

---

## 0. Como o Agente Deve Operar

### Protocolo de entrada (sempre execute antes de qualquer trabalho)

1. **Leia `Estado de Execução`** (seção 1). Identifique última task tocada e branch ativa.
2. **Verifique reality vs. plano**:
   - `git status` — há trabalho não commitado?
   - `git log --oneline -20` — o que foi feito desde a última atualização do plano?
   - Se houver divergência, atualize `Estado de Execução` antes de prosseguir.
3. **Escolha a próxima task** com:
   - `status: pending`
   - todas as `depends_on` em `status: completed`
   - menor ID disponível
4. Marque a task como `in_progress`, registre `agent`, `started_at`, `branch`.

### Protocolo de saída (sempre execute ao parar)

1. Se a task ficou parcial, registre em `notes` exatamente:
   - últimos arquivos tocados (com linha aproximada)
   - próximo passo concreto
   - comando de verificação que deve passar
2. Atualize `Estado de Execução` com timestamp e resumo de uma linha.
3. Commit local com mensagem `wip(TASK-NNN): <resumo>` se houver código não commitado.
4. **Nunca** marque `completed` se algum critério de aceite falhou.

### Regras invioláveis

- Rodar `Invoke-Pester -Path .\tests -EnableExit` com Pester 3.4.0 antes de marcar qualquer task como `completed`.
- Rodar o `Parser::ParseFile` em `bootstrap-tools.ps1` e `bootstrap-ui.ps1` antes de commit.
- Nenhum secret/token real em qualquer arquivo, log ou test fixture.
- `Set-StrictMode -Version Latest` e `$ErrorActionPreference = 'Stop'` permanecem no topo de todo script.
- Mudanças que mutam o host obrigam chamada a `Register-BootstrapChange` (a TASK-011/012 vai automatizar essa checagem).
- Se travar 2× na mesma task, **pare** e registre em `## Bloqueios`. Não force.

### Convenção de commit por task

```
<tipo>(TASK-NNN): descrição curta

Detalhes opcionais.
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```
`<tipo>` ∈ `feat | fix | refactor | test | docs | chore`.

### Reset de contexto seguro

Se um agente novo entra sem histórico: este arquivo + `CLAUDE.md` + `git log --oneline -30` + última task `in_progress` é tudo que ele precisa. Não confie em memória ambiental.

---

## 1. Estado de Execução

| Campo | Valor |
|---|---|
| Última atualização | 2026-05-27 (Support robustness + WSL Repair + BAT/UI/ReleasePack; Pester 392/392 verde nesta maquina) |
| Agente responsável | Codex |
| Branch ativa | `codex-bootstrap-secrets-rotation` |
| Task em andamento | nenhuma |
| Próxima task sugerida | revisar diffs grandes e separar commits por escopo antes de PR/merge |
| Pester versão alvo | 3.4.0 (lock CI) |
| PowerShell alvo | 5.1 (PS7 só na Fase 3) |

**Resumo de uma linha (preencha a cada sessão):**

- 2026-05-13 — Plano criado a partir do parecer estratégico. Branch `codex-bootstrap-secrets-rotation` tem trabalho parcial não validado.
- 2026-05-13 — TASK-001 concluída. Branch tem core de secrets (~30 funções) + rotação manual via `Move-BootstrapSecretsToNextCredential`. Gaps: fila programática, timeout exposto, retry/backoff, scheduler, eventos estruturados, `Register-BootstrapChange` em ativação/rotação, lock cross-process. Re-estimativa: 27h → 31h. Nova TASK-006a (isolar commits) adicionada. Pester baseline 18/18 verde.
- 2026-05-14 — TASK-002 concluída. ADR `docs/adr/0001-secrets-rotation-state-machine.md` definido: 6 estados (queued→validating→activating→broadcasting→settled|failed), retry exponencial com jitter, timeout 15s/validador e 120s/item, lock por arquivo `.lock`, eventos JSONL, broadcast com `minBroadcastSuccess=1`, rollback via `Register-BootstrapChange`. Compatibilidade preservada com `Move-BootstrapSecretsToNextCredential` (vira thin wrapper).
- 2026-05-14 — TASK-003 concluída. 11 novas funções em `bootstrap-tools.ps1` (linhas ~14302+): `Get-/Add-/Update-/Invoke-BootstrapSecretRotation*`, `Lock-/Unlock-BootstrapSecretsFile`, `Write-BootstrapRotationEvent`, `Get-BootstrapSecretsValidationFailureCategory`, `Test-BootstrapSecretsRetryableFailure`. `Test-BootstrapSecretsProviderCredential` ganhou `-TimeoutSeconds` (1–120, default 15). `Register-BootstrapChange` ganhou tipo `'SecretsRotation'`. `Convert-BootstrapSecretsProviderDefinition` agora preserva `rotationQueue`. Novo arquivo `tests/bootstrap-secrets-rotation.tests.ps1` com 13 `It`. **Resultado final: Pester 325/325 verde** (suite inteira). Parse OK em ambos `.ps1`. Mudanças aditivas — nenhum teste pré-existente quebrou.
- 2026-05-15 — Verificação após interrupção do agente anterior. Suite cresceu para 343 testes (TASK-004/008/009/010 já presentes no working tree não commitado): `-RotateSecrets` CLI mode + `Invoke-BootstrapRotateSecretsMode` + `Get-BootstrapRotationStaleProviders` + `Register-BootstrapRotationScheduledTask`; `tests/bootstrap-secrets-rotation-cli.tests.ps1` cobre stale detection, scheduler dry-run, end-to-end rotate mode, UI Contract `secretsRotation` block e cap de 1000 linhas em `rotation-events.jsonl`. UI Contract ganhou `schemaVersion=1.0.0` + `secretsRotation.{schedule,eventsPath}`; `bootstrap-ui.ps1` ganhou `Test-UiContractVersionCompat` + constantes `$Script:UiContractMin/MaxSupported`; novos testes `bootstrap-ui-contract-snapshot.tests.ps1` (4 It) e `bootstrap-ui-contract-version.tests.ps1` (5 It) + fixture `tests/fixtures/ui-contract-v1-keys.json`. Fixes aplicados nesta sessão: (1) `Add-BootstrapSecretRotationItem` validava `credentials` com `-is [hashtable]` mas `Normalize-...` retorna `OrderedDictionary` — afrouxado para `[System.Collections.IDictionary]`; (2) `Invoke-WebRequestWithRetry` lia `$script:Offline` do escopo do orquestrador, inacessível pelo test de `tests/resilience.tests.ps1` — adicionado fallback para `$Global:BootstrapOfflineOverride`; (3) testes usavam `Should Throw` sem mensagem que Pester 3.4 não captura quando `$ErrorActionPreference='Stop'` — trocado por `Should Throw '<msg>'`; (4) timeout do `Invoke-InstallCliBat` em `tests/ai-tools.tests.ps1` elevado de 120s→240s (execução real leva ~155s). **Resultado final: Pester 343/343 verde**, parse OK em ambos `.ps1`, `cmd /c .\bootstrap-ui.bat -SmokeTest` emite JSON sem stderr, `.\bootstrap-tools.ps1 -RotateSecrets -DryRun -NonInteractive` produz JSON estruturado.
- 2026-05-16 — Validação independente após rewrite reportado: suite completa inicialmente não pôde ser confirmada e dois arquivos falharam isolados. Correções aplicadas: `New-Guid` trocado por `[Guid]::NewGuid()` em `tests/resilience.tests.ps1` para PS 5.1; timeout do teste de `Read-UiBackendResultWithRetry` aumentado para cobrir latência real de `Start-Job` no host. Verificação final nesta máquina: arquivos alterados por arquivo verdes, parse OK, ScriptAnalyzer Error OK, `bootstrap-ui.bat -SmokeTest` OK, `bootstrap-tools.ps1 -RotateSecrets -DryRun -NonInteractive` exit 0 com falha auth esperada nas credenciais locais `github`/`xai`, Pester completo **343/343 verde**.
- 2026-05-16 — Validação real via `.bat`: `bootstrap-ui.bat -SmokeTest` emitiu JSON parseável sem stderr; `install-cli.bat --tool rtk --validate --yes` retornou `configured` com `rtk 0.40.0` e diagnóstico vazio; `install-cli.bat -Profile safe-base -NonInteractive` retornou `success`, 12 plugins Notepad++ aplicados, zero warnings/diagnostics. Correções adicionais: diagnóstico AI tools não classifica `installed/configured` como erro; Notepad++ usa SHA256 .NET interno, cache por plugin e JSTool foi diferido porque SourceForge devolve HTML no fluxo automatizado. Pester completo **346/346 verde**.
- 2026-05-17 — Diagnóstico de produto implementado: `-Audit` ganhou `-AuditTimeoutSeconds`/`-AuditComponentTimeoutSeconds`, fallback winget curto, `durationMs`/`timedOut`/`probeSource` no resultado, DPAPI para `bootstrap-secrets.json`, Pester quality gates para PSScriptAnalyzer budget e mutações sem `Register-BootstrapChange`. Verificação: parse OK, PSScriptAnalyzer 0 errors, `-Audit -DryRun` 48 componentes em ~39s, `bootstrap-ui.bat -SmokeTest` OK, `safe-base -DryRun` success, Pester completo **356/356 verde**.
- 2026-05-18 — Support Robustness Track implementado: modos `-Doctor`, `-SupportBundle`, `-RepairPlan`, `-ExecuteRepairPlan`; UI Saúde; perfil `public-beta`; apps opcionais de suporte; RunId único em log/result/support bundle para evitar colisão entre processos paralelos. Verificação: parse OK, PSScriptAnalyzer 0 errors/694 warnings, Pester completo **361/361 verde**, `bootstrap-ui.bat -SmokeTest` OK, `safe-base -DryRun` OK, `-Audit -DryRun` OK, `-Doctor -DryRun` OK.
- 2026-05-19 — Steam Deck Support Read-Only Track implementado: `doctor.deck`, artefatos `deck-*.json` no SupportBundle, UI Saúde mostra status Steam Deck, UiContract `1.3.0` com `steamDeckDoctor`; execução read-only, sem reparos automáticos. Verificação: parse OK, PSScriptAnalyzer 0 errors/705 warnings, Pester completo **363/363 verde**, UI smoke OK, `-Doctor -DryRun` OK, `-SupportBundle -DryRun` OK.
- 2026-06-03 - AI Proxy Suite corrigida para separar config/deps de runtime real; 4 proxies HTTP escutando e respondendo `/v1/models`, Antigravity degradado por upstream 503, Pester completo **454/454 verde**.

---

## Current Execution Checklist

- status: validated
- scope: AI Proxy Suite runtime real, start action, Doctor/Audit runtime probes, bundle redigido, full QA
- branch: codex-bootstrap-secrets-rotation
- files changed: bootstrap-tools.ps1, install-cli.ps1, bootstrap-ui.bat, bootstrap-ui.ps1, tests/ai-proxy-suite.tests.ps1, tests/ai-tools.tests.ps1, tests/bootstrap-launcher-diagnostics.tests.ps1, tests/bootstrap-quality-gates.tests.ps1, tests/bootstrap-secrets-rotation-cli.tests.ps1, tests/bootstrap-support-robustness.tests.ps1, tests/fixtures/ui-contract-v1-keys.json, AGENT_EXECUTION_PLAN.md
- TDD added: proxy deps without listener => start-required; suite stopped => not ready; listener with `/v1/models` error => unhealthy; start dry-run plan; Go proxy start without ArgumentList; Go proxy fallback to `go run`; no duplicate process when port already listens; install-cli `--start` dry-run and blocked exit tests.
- implementation: Doctor/Audit now record listening, pid, processName, healthStatus, modelsStatus and runtime probe duration; proxy status only becomes configured when port listens and `/v1/models` answers; `ai-proxy-suite` has real start action, runtime state files and logs under LocalAppData; Mimo falls back to `go run main.go` when compiled exe is blocked by App Control; IDE default no longer implies runtime availability.
- real proxy status: kimiproxy 3010 configured; qwenproxy 3011 configured; deepsproxy 3012 configured; mimo-ai-proxy 3013 configured via `go run`; antigravity-openai-adapter 8081 unhealthy because upstream `/v1/models` returns 503; dockernativemanager desktop configured/not HTTP.
- validation commands: targeted `tests/ai-proxy-suite.tests.ps1` 13/13 OK; targeted `tests/ai-tools.tests.ps1` 18/18 OK; parse all git-tracked ps1 OK count=60; PSScriptAnalyzer tracked files Error=0 and Warning=690/705 OK; `tests\run-pester.ps1 -NoInstall` 454/454 OK in 1370.57s; `bootstrap-ui.bat -SmokeTest` OK; `bootstrap-ui.bat -SmokeTestWindow` OK; `install-cli.ps1 --tool ai-proxy-suite --validate --yes --no-admin` exit 0 status unhealthy; `bootstrap-tools.ps1 -Doctor -DryRun -NonInteractive` exit 0; `-SupportBundle -DryRun -NonInteractive` exit 0; `-RepairPlan -DryRun -NonInteractive` exit 0; `-Audit -DryRun -NonInteractive` exit 0; `-Profile safe-base -DryRun -NonInteractive` exit 0; `install-cli.bat --tool ai-proxy-suite --start --dry-run --yes --no-admin` exit 0.
- support bundle: `C:\Users\misae\AppData\Local\Temp\phasezero-support_20260603_064519_24484_93100e84.zip`; 19 entries; no `.env` entry; no `bootstrap-secrets.json` entry; no hits for real token patterns (`sk-`, `sk-or-`, `sk-ant-`, `ghp_`, `github_pat_`, provider env names, `protectedData`). Only two redacted textual path refs to `bootstrap-secrets.json` in doctor/result.
- blockers: Antigravity local upstream on 8080 answers health but returns 503 for `/v1/models`; Doctor/Audit correctly mark degraded instead of healthy. Host still has unrelated Python App Control warning, WSL restart/service warnings and optional app gaps.
- next task: fix Antigravity upstream model endpoint/config, then rerun `install-cli.ps1 --tool ai-proxy-suite --validate --yes --no-admin` until suite becomes ready.

## 2. Roadmap em Fases

| Fase | Janela | Objetivo | Tasks |
|---|---|---|---|
| **Fase 1 — Estabilização** | 0–90 dias | Fechar dívidas críticas: rotação de secrets, contrato UI, rollback enforcement, cobertura | TASK-001..TASK-017 |
| **Fase 2 — Modularização** | 90–180 dias | Quebrar monólito em módulos testáveis | TASK-018..TASK-023 |
| **Fase 3 — Cross-platform & Telemetria** | 180+ dias | PS7, Linux Steam Deck, telemetria opt-in | TASK-024..TASK-031 |

Critério para passar de fase: 100% das tasks da fase anterior em `completed`, CI verde por 7 dias corridos, zero bloqueios abertos.

---

## 3. Backlog de Tasks

### Convenção de cabeçalho

```
### TASK-NNN: título imperativo
- status: pending | in_progress | blocked | completed
- depends_on: [TASK-XXX, ...]
- estimated_hours: N
- agent: <nome ou — >
- started_at / completed_at: ISO-8601
- branch: nome-da-branch
- files_touched: lista (preencha durante execução)
```

---

### Fase 1 — Estabilização

#### TASK-001: Auditar branch `codex-bootstrap-secrets-rotation`
- **status:** pending
- **depends_on:** —
- **estimated_hours:** 2
- **objetivo:** Mapear o que está feito vs. faltando para rotação automática de secrets.
- **passos:**
  1. `git checkout codex-bootstrap-secrets-rotation`
  2. `git diff main...HEAD --stat` — salve em `.bootstrap-tools/task-001-diff.txt` (gitignored).
  3. Para cada função tocada em `bootstrap-tools.ps1`, anote: nome, propósito, estado (completo/parcial/quebrado).
  4. Liste testes existentes em `tests/bootstrap-secrets*.tests.ps1` e o que cobrem.
  5. Produza seção `### TASK-001 Findings` no final deste arquivo com:
     - funções já existentes ligadas a rotação
     - gaps (validador? scheduler? fila? notificação? UI?)
     - estimativa atualizada de horas para TASK-002..TASK-007
- **critério de aceite:** seção Findings preenchida; plano TASK-002..007 ajustado se necessário.
- **verificação:** `Invoke-Pester -Path .\tests\bootstrap-secrets.tests.ps1 -EnableExit` ainda passa.
- **rollback:** nenhum (só leitura).
- **handoff:** se interrompido, próximo agente lê `task-001-diff.txt` e continua na função onde parou.

#### TASK-002: Desenhar máquina de estados da rotação
- **status:** pending
- **depends_on:** [TASK-001]
- **estimated_hours:** 3
- **objetivo:** Documentar estados (`queued → validating → activating → broadcasting → settled | failed`) e transições.
- **passos:**
  1. Escreva ADR em `docs/adr/0001-secrets-rotation-state-machine.md` (criar pasta se necessário).
  2. Defina: entradas que disparam rotação, validação, ativação atômica, broadcast a consumidores (MCPs, OpenCode, Continue…), critério de sucesso, política de retry/backoff, timeout total, ação em falha (manter credencial antiga ativa, marcar `validation.state = failed`).
  3. Defina forma serializada em `.bootstrap-tools/bootstrap-secrets.json` para fila de rotação.
- **critério de aceite:** ADR aprovado por inspeção (sem ambiguidade em transições). Diagrama ASCII obrigatório.
- **verificação:** revisão manual; checklist no final do ADR.

#### TASK-003: Implementar worker de fila de rotação
- **status:** pending
- **depends_on:** [TASK-002]
- **estimated_hours:** 8
- **objetivo:** Função `Invoke-BootstrapSecretRotation` que consome a fila respeitando a state machine.
- **passos:**
  1. Em `bootstrap-tools.ps1`, criar:
     - `Get-BootstrapSecretRotationQueue`
     - `Add-BootstrapSecretRotationItem`
     - `Invoke-BootstrapSecretRotationItem` (executa uma transição)
     - `Invoke-BootstrapSecretRotation` (loop sobre fila com `-MaxItems`, `-TimeoutSeconds`)
  2. Toda mutação ao manifest passa por `Save-BootstrapSecretsManifest` com lock (já existe — confirmar).
  3. Toda mutação ao host (ex.: broadcast a IDE) chama `Register-BootstrapChange`.
  4. Mascarar tokens em todo log.
  5. Timeout obrigatório por validador (default 15s, override via parâmetro).
- **critério de aceite:**
  - função definida antes do run-guard (library mode carrega).
  - dry-run `-DryRun` não mexe em arquivos.
  - logs nunca contêm valor de token (grep no log artificial deve falhar).
- **verificação:**
  - Pester 3.4.0 verde.
  - `parse` sem erros nos dois `.ps1`.
- **rollback:** `git revert <commit>` — função é aditiva.

#### TASK-004: Trigger agendado de rotação
- **status:** pending
- **depends_on:** [TASK-003]
- **estimated_hours:** 4
- **objetivo:** Permitir `-RotateSecrets` na CLI e agendamento opcional via Task Scheduler.
- **passos:**
  1. Adicionar flag `-RotateSecrets` em `bootstrap-tools.ps1` (param block + dispatch no run-guard).
  2. Adicionar subcomponente em `bootstrap-secrets` que registra tarefa agendada Windows (Task Scheduler) — opt-in via UI Contract.
  3. Expor no `-UiContractJson` campo `secretsRotation.schedule` (none|daily|weekly).
  4. Registrar a tarefa via `Register-BootstrapChange` (categoria `scheduled-task`) para rollback.
- **critério de aceite:** `.\bootstrap-tools.ps1 -RotateSecrets -DryRun -NonInteractive` produz plano coerente sem efeitos.
- **verificação:** novo teste em `tests/bootstrap-secrets-rotation.tests.ps1` cobre flag e dry-run.

#### TASK-005: Superfície de notificação
- **status:** pending
- **depends_on:** [TASK-003]
- **estimated_hours:** 3
- **objetivo:** Eventos de rotação (sucesso/falha) gravados em log estruturado consumível pela UI.
- **passos:**
  1. Criar `Write-BootstrapRotationEvent` que escreve JSON-lines em `.bootstrap-tools/rotation-events.jsonl`.
  2. UI Contract expõe `secretsRotation.eventsPath`.
  3. `bootstrap-ui.ps1` lê últimos N eventos e mostra em painel (apenas hook — UI completa fica para TASK-013 da Fase 2).
- **critério de aceite:** arquivo de eventos válido JSON-line, max 1000 entradas (rotação de log).

#### TASK-006: Testes de rotação (happy + falhas)
- **status:** pending
- **depends_on:** [TASK-003, TASK-004, TASK-005]
- **estimated_hours:** 6
- **objetivo:** Cobrir state machine inteira com Pester 3.4.0.
- **casos obrigatórios:**
  - rotação bem-sucedida ponta-a-ponta com mock de validador.
  - validador lento estoura timeout → estado `failed`, credencial antiga permanece ativa.
  - broadcast parcial (3 de 5 consumidores) → retry; após N falhas, registra evento `partial`.
  - falha catastrófica → `Register-BootstrapChange` permite `-Rollback` reverter.
  - concorrência: duas chamadas simultâneas → segunda detecta lock e aborta limpa.
- **critério de aceite:** ≥ 12 novos `It` blocks; 0 testes flaky em 10 execuções consecutivas.

#### TASK-007: Merge `codex-bootstrap-secrets-rotation` → `main`
- **status:** pending
- **depends_on:** [TASK-001..TASK-006]
- **estimated_hours:** 1
- **passos:**
  1. Rebase final em `main`, resolver conflitos.
  2. Verificação: `parse` + Pester 3.4.0 verde.
  3. PR com descrição apontando para este plano (TASK-001..007).
- **critério de aceite:** PR aprovado; CI verde; branch deletada.

---

#### TASK-008: Adicionar `schemaVersion` ao UI Contract
- **status:** pending
- **depends_on:** —
- **estimated_hours:** 2
- **objetivo:** Versionar o JSON emitido por `-UiContractJson`.
- **passos:**
  1. Em `bootstrap-tools.ps1`, na função que monta o contrato, adicionar campo top-level `schemaVersion = "1.0.0"`.
  2. Documentar regra SemVer: minor para adições compatíveis, major para remoções/renames.
  3. Em `bootstrap-ui.ps1`, ler o campo e armazenar em `$Script:UiContractVersion`.
- **critério de aceite:** `bootstrap-tools.ps1 -UiContractJson | ConvertFrom-Json` traz `schemaVersion`.

#### TASK-009: Negociação UI ↔ Orchestrator
- **status:** pending
- **depends_on:** [TASK-008]
- **estimated_hours:** 4
- **objetivo:** UI rejeita major incompatível, avisa em minor mais nova.
- **passos:**
  1. UI tem constante `$Script:UiContractMinSupported = "1.0.0"` e `$Script:UiContractMaxSupported = "1.X.X"`.
  2. Major maior que `Max` → mensagem "Atualize a UI" e exit.
  3. Major menor que `Min` → mensagem "CLI desatualizada" e exit.
  4. Minor maior que UI suporta → warn, continua.
- **critério de aceite:** teste em `tests/bootstrap-ui-contract-version.tests.ps1` cobre os 3 caminhos.

#### TASK-010: Snapshot test do UI Contract
- **status:** pending
- **depends_on:** [TASK-008]
- **estimated_hours:** 3
- **objetivo:** Detectar remoção acidental de campos.
- **passos:**
  1. Gerar snapshot do contrato em `tests/fixtures/ui-contract-v1.json`.
  2. Teste compara estrutura (não valores) — falha se faltar chave; warn se sobrar.
  3. Quando intencionalmente quebrar, atualizar snapshot + bumpar `schemaVersion`.
- **critério de aceite:** teste passa hoje; falha previsivelmente se removermos um campo.

---

#### TASK-011: Inventariar funções mutadoras sem `Register-BootstrapChange`
- **status:** pending
- **depends_on:** —
- **estimated_hours:** 4
- **objetivo:** Listar gaps de rollback.
- **passos:**
  1. Script auxiliar (não commitar — usar `.bootstrap-tools/`) que parseia AST de `bootstrap-tools.ps1` procurando:
     - chamadas a `Set-ItemProperty`, `New-Item`, `Remove-Item`, `Set-Service`, `winget install`, `choco install`, `Invoke-WebRequest -OutFile`, `[Environment]::SetEnvironmentVariable`, etc.
     - verifica se a função contendo essas chamadas também chama `Register-BootstrapChange` no mesmo escopo.
  2. Produz lista em `### TASK-011 Findings` neste arquivo.
- **critério de aceite:** lista com ≥ 1 entrada por função problemática, com linha aproximada.

#### TASK-012: Lint via Pester forçando registro de mudanças
- **status:** pending
- **depends_on:** [TASK-011]
- **estimated_hours:** 5
- **objetivo:** CI quebra se função mutadora não chama `Register-BootstrapChange`.
- **passos:**
  1. Novo teste `tests/bootstrap-change-registration.tests.ps1`.
  2. Lista de funções isentas explícita (allow-list) — qualquer outra mutadora deve registrar.
  3. Usa AST PowerShell para detectar.
- **critério de aceite:** teste falha contra estado atual (até TASK-013 corrigir); passa depois.

#### TASK-013: Corrigir gaps identificados em TASK-011
- **status:** pending
- **depends_on:** [TASK-011, TASK-012]
- **estimated_hours:** 8
- **objetivo:** Toda mutadora real registra mudança.
- **passos:** Para cada item da lista de TASK-011, adicionar chamada apropriada a `Register-BootstrapChange` ou justificar isenção na allow-list de TASK-012.
- **critério de aceite:** teste de TASK-012 verde sem exceções não justificadas.

#### TASK-014: Adicionar lint ao CI
- **status:** pending
- **depends_on:** [TASK-012, TASK-013]
- **estimated_hours:** 1
- **objetivo:** Garantir que regressões sejam pegas no PR.
- **passos:** Já roda em `Invoke-Pester`; apenas documentar em `AGENTS.md` que essa convenção é checada.

---

#### TASK-015: Suite de integração `secrets → MCP → consumidor`
- **status:** pending
- **depends_on:** [TASK-006]
- **estimated_hours:** 8
- **objetivo:** Garantir que credencial reprovada não vaza para nenhum consumidor.
- **passos:**
  1. Em `tests/integration/secrets-mcp.tests.ps1`:
     - cenário 1: credencial `validation.state = passed` → MCP recebe; consumidor (mock Claude Code config) reflete.
     - cenário 2: credencial `failed` → MCP **não** recebe; consumidor mantém valor anterior ou ausente.
     - cenário 3: rotação muda credencial ativa → todos consumidores atualizam.
     - cenário 4: provider em bypass list (`context7`, `firecrawl`, `apify`, `netdata`, `supabase`) ignora validação.
- **critério de aceite:** ≥ 8 `It`, 0 flaky.

#### TASK-016: Teste de checkpoint sob crash
- **status:** pending
- **depends_on:** —
- **estimated_hours:** 6
- **objetivo:** Garantir que `-Resume` recupera após queda.
- **passos:**
  1. Simular falha injetando exceção em meio de pipeline (mockar componente).
  2. Verificar manifesto + checkpoint consistentes.
  3. Rodar com `-Resume` e verificar conclusão correta.
- **critério de aceite:** 4 cenários de crash diferentes (disco cheio, exception, kill simulado, NTFS abort).

#### TASK-017: Teste round-trip UI → CLI → UI
- **status:** pending
- **depends_on:** [TASK-008..TASK-010]
- **estimated_hours:** 4
- **objetivo:** Garantir que seleção feita na UI é interpretada idêntica pela CLI.
- **passos:**
  1. Gerar `selection.json` mock em `tests/fixtures/`.
  2. Invocar CLI em dry-run com a seleção.
  3. Comparar plano gerado vs. esperado (snapshot).
- **critério de aceite:** snapshot estável; quebra previsível se semântica de seleção mudar.

---

### Fase 2 — Modularização (resumo, expandir ao chegar)

#### TASK-018: Documento de fronteiras de módulo
- **status:** pending
- **depends_on:** [TASK-007, TASK-013, TASK-017]
- **estimated_hours:** 6
- **objetivo:** ADR definindo: `Bootstrap.Core` (logging, paths, JSON), `Bootstrap.Resilience` (checkpoint, rollback, audit), `Bootstrap.Secrets`, `Bootstrap.MCP`, `Bootstrap.Components`, `Bootstrap.UI`.
- **entregável:** `docs/adr/0002-modularization.md` com dependências unidirecionais (sem ciclos).

#### TASK-019..TASK-022: Extrair módulos um a um
- **status:** pending
- **depends_on:** [TASK-018]
- **estimated_hours:** 12 cada
- **regra crítica:** após cada extração, `bootstrap-tools.ps1 -BootstrapUiLibraryMode` ainda carrega tudo (via `Import-Module`). Pester verde a cada PR.

#### TASK-023: Ajustar library mode e UI Contract
- **status:** pending
- **depends_on:** [TASK-019..TASK-022]
- **estimated_hours:** 6
- **objetivo:** Após split, library mode importa módulos em vez de redefinir. Contract permanece estável.

---

### Fase 3 — Cross-platform & Telemetria (resumo)

#### TASK-024: Auditoria PS5 → PS7
- **estimated_hours:** 8
- **entregável:** lista de incompatibilidades (array flattening, `using`, classes, native cmds).

#### TASK-025: Refatorar padrões PS5-only
- **depends_on:** [TASK-024]
- **estimated_hours:** 16

#### TASK-026: Camada de abstração Windows/Linux
- **depends_on:** [TASK-025]
- **estimated_hours:** 24
- **escopo:** registry → config files, services → systemd, package managers → winget/flatpak/apt.

#### TASK-027: Modo Linux do Steam Deck
- **depends_on:** [TASK-026]
- **estimated_hours:** 20

#### TASK-028: Fluxo de consentimento de telemetria
- **estimated_hours:** 4

#### TASK-029: Hooks de instrumentação
- **depends_on:** [TASK-028]
- **estimated_hours:** 6

#### TASK-030: Camada de redação (secrets, paths pessoais)
- **depends_on:** [TASK-029]
- **estimated_hours:** 4

#### TASK-031: Endpoint opcional para envio
- **depends_on:** [TASK-029, TASK-030]
- **estimated_hours:** 6

---

## 4. Bloqueios

> Registre aqui qualquer task que travou 2× ou depende de decisão humana. Formato:

```
### BLOQ-NNN — <título>
- task afetada: TASK-NNN
- data: ISO
- descrição: …
- precisa de: <decisão / acesso / informação>
- agente: <nome>
```

### BLOQ-001 — Working tree pré-existente misturado com TASK-001..003

- task afetada: TASK-007 (merge final), TASK-006a (isolar commits)
- data: 2026-05-14
- descrição: branch `codex-bootstrap-secrets-rotation` já tinha 12 arquivos modificados não-commitados ao iniciar TASK-001 (`AGENTS.md`, `README.md`, `bootstrap-tools.ps1`, vários `tests/*.ps1`, etc.) + 3 untracked (`RTK.md`, `Setup-AITools.ps1`, `tests/run-pester-runner.tests.ps1`). Essas mudanças **não são** trabalho do agente de rotação — são WIP anterior do dev humano.
- impacto: as adições da TASK-003 em `bootstrap-tools.ps1` (worker + Register-BootstrapChange ValidateSet + preservação de `rotationQueue`) estão **misturadas** no working tree com diff alheio.
- precisa de: confirmação do dev humano sobre destino das mudanças pré-existentes. Opções:
  1. Commitar tudo junto em `wip(TASK-003)` (rápido, sujo).
  2. Isolar trecho da rotação via `git diff` + patch (preserva separação).
  3. Esperar dev humano commit do WIP dele primeiro; agente comita por cima.
- agente: Claude Opus 4.7
- estado atual: **resolvido em 2026-05-15** via 2 commits separados conforme decisão do dev humano: (1) `feat(TASK-003..010)` agrupa worker rotação + scheduler + UI Contract schemaVersion + testes novos + fixes desta sessão; (2) `wip(misc)` agrupa o WIP alheio (AGENTS.md, README.md, SteamDeck.Common.ps1, 5 tests modificados, RTK.md, Setup-AITools.ps1, run-pester-runner.tests.ps1). Suite 343/343 verde antes de cada commit. CI pode rodar contra ambos limpamente.

---

## 5. Log de Decisões

> Registre escolhas técnicas não-óbvias. Não delete entradas.

- **2026-05-13 / DEC-001** — Manter Pester 3.4.0 como alvo de CI por toda Fase 1. Migrar Pester só na Fase 2 junto com modularização.
- **2026-05-13 / DEC-002** — `schemaVersion` do UI Contract usa SemVer estrito; bumps coordenados com release de UI.
- **2026-05-13 / DEC-003** — PS7 fica fora de Fase 1/2; tocar antes adiciona risco sem destravar valor proporcional.
- **2026-05-14 / DEC-004** — Fila de rotação vive dentro de `bootstrap-secrets.json` (chave `providers.<name>.rotationQueue`), não em arquivo separado. Único ponto de verdade, write atômico.
- **2026-05-14 / DEC-005** — Lock baseado em arquivo (`.lock` ao lado do manifest, `FileShare::None`) com timeout 5s. Mutex nomeado descartado por complexidade.
- **2026-05-14 / DEC-006** — Erros de validação `401/403` são terminais (sem retry). `5xx/timeout/429` são retryáveis com backoff exponencial + jitter, até `maxAttempts=3`.
- **2026-05-14 / DEC-007** — `Move-BootstrapSecretsToNextCredential` vira thin wrapper sobre o worker novo. Compatibilidade pública preservada para não quebrar testes e `Invoke-BootstrapSecretsMode`.
- **2026-05-15 / DEC-008** — `Add-BootstrapSecretRotationItem` valida `credentials` com `[System.Collections.IDictionary]` (não `[hashtable]`) porque `Normalize-BootstrapSecretsData` produz `OrderedDictionary`. Aplicar a mesma regra em qualquer checagem futura de containers normalizados.
- **2026-05-15 / DEC-009** — Pester 3.4 com `$ErrorActionPreference='Stop'` exige `Should Throw '<msg-parcial>'`. `Should Throw` sem mensagem é silenciosamente falso-negativo. Padronizar em todos os novos testes.
- **2026-05-15 / DEC-010** — Fluxo de Offline cache em `Invoke-WebRequestWithRetry` aceita override via `$Global:BootstrapOfflineOverride` para testabilidade — `$script:Offline` continua sendo o canal de produção (param block).

---

## 6. Histórico

> Tasks completadas vão para cá com link para commit/PR.

- **TASK-001 (auditoria branch)** — 2026-05-13. Findings em §"TASK-001 Findings".
- **TASK-002 (ADR state machine)** — 2026-05-14. `docs/adr/0001-secrets-rotation-state-machine.md`. Commit `28bd922`.
- **TASK-003 (worker fila rotação)** — 2026-05-14 (implementação) + 2026-05-15 (commit isolado). 11 funções em `bootstrap-tools.ps1`, classificação 401/timeout/server/rate-limit, lock cross-process, eventos JSONL.
- **TASK-004 (CLI `-RotateSecrets` + scheduler)** — 2026-05-15. `Invoke-BootstrapRotateSecretsMode`, `Register-BootstrapRotationScheduledTask`, `Get-BootstrapRotationStaleProviders`, UI Contract `secretsRotation.schedule`. Verificação: `.\bootstrap-tools.ps1 -RotateSecrets -DryRun -NonInteractive` retorna JSON estruturado.
- **TASK-005 (notificação eventos)** — 2026-05-15. `Write-BootstrapRotationEvent` + cap de 1000 linhas em `rotation-events.jsonl`, exposto via `secretsRotation.eventsPath` no contrato.
- **TASK-008 (UI Contract schemaVersion)** — 2026-05-15. Top-level `schemaVersion = "1.0.0"`.
- **TASK-009 (negociação UI ↔ Orchestrator)** — 2026-05-15. `Test-UiContractVersionCompat` + 5 `It` cobrindo accept/warn/error-major-new/error-major-old/malformed.
- **TASK-010 (snapshot test do contrato)** — 2026-05-15. `tests/fixtures/ui-contract-v1-keys.json` + 4 `It`.

---

## TASK-001 Findings (2026-05-13)

### Escopo real da branch `codex-bootstrap-secrets-rotation`

A branch **não é só rotação de secrets**. Tem 22 commits e ~32k linhas adicionadas vs. `main` (6cccd32). O subset relevante a TASK-001..007 é:

- spec: `docs/superpowers/specs/2026-04-18-bootstrap-secrets-manifest.md` (228 linhas, já cobre fluxo manual de rotação)
- código em `bootstrap-tools.ps1` (lines ~8400–20000 cobrem secrets)
- testes em `tests/bootstrap-secrets.tests.ps1` (675 linhas) + `tests/bootstrap-secrets.performance.tests.ps1` (19 linhas)

### Funções de secrets/rotação já presentes (ligadas à linha)

**Modelagem do manifest (linhas 8426–10915):**
- `Get-BootstrapSecretsManifestCredentialCount`, `Test-BootstrapSecretsManifestHasCredentials`
- `Get-BootstrapSecretsPath`, `Get-BootstrapSecretsKnownTargets`, `Get-BootstrapSecretsProviderCatalog`
- `New-BootstrapSecretValidationState`, `New-BootstrapSecretCredentialId`
- `Normalize-BootstrapSecret(Validation|Credential|sData)`, `Convert-BootstrapSecretsProviderDefinition`, `Get-BootstrapSecretsTemplate`
- `Get-BootstrapSecretValueByPath`, `Resolve-BootstrapSecretTemplates`
- `Add-BootstrapImportedCredential`, `Import-BootstrapSecretsText`, `Get-BootstrapSecretsTokenMatches`
- `Get-BootstrapSecretsListEntries`, `Get-BootstrapResolvedSecretsTargets`, `Get-BootstrapSecretsDiagnostics`, `Get-BootstrapSecretsData`

**Validação e ativação (linhas 14090–14300):**
- `Test-BootstrapSecretsProviderCredential` (validador real por provider)
- `Invoke-BootstrapSecretsValidation` (revalida todas ou só a ativa)
- `Set-BootstrapSecretsActiveCredential` (ativa apenas se passar validação)
- `Move-BootstrapSecretsToNextCredential` (rotação manual — gira para a próxima válida)
- `Test-BootstrapSecretsTargetHasApplicableValues`

**Broadcast a consumidores (linhas 14341–15144):**
- `Ensure-BootstrapUserEnvSecrets`, `Ensure-Bootstrap{ZCode,VsCode,Roo,Cline,Zed,OpenClaw,Hermes,Kilo,Comet,ClaudeCode,ClaudeDesktop,Cursor,Windsurf,Trae,OpenCode}Secrets`
- `Ensure-BootstrapSecrets` (orquestrador único, linha 16878)

**API Center / UI (linhas 19776–19996):**
- `Set-BootstrapSecretsPreferredActiveCredentials` (com `-ForceFirstPassed` / `-OnlyWhenMissing`)
- `Write-BootstrapSecretsList`
- `Set-BootstrapApiCredential`, `Invoke-BootstrapApiCredentialValidation`, `Set-BootstrapApiActiveCredential`, `Import-BootstrapApiCredentialFile`, `Invoke-BootstrapApiApply`

**Dispatcher CLI (linhas 20004–20065):**
- `Invoke-BootstrapSecretsMode` lê os parâmetros `-SecretsImportPath`, `-SecretsValidateAll`, `-SecretsActivateProvider`, `-SecretsActivateCredential`, `-SecretsList`.

**Flags CLI já no param block (linhas 16–30):**
- `[string]$SecretsImportPath` / `$SecretsActivateProvider` / `$SecretsActivateCredential`
- `[switch]$SecretsList` / `$SecretsValidateAll`

### Testes existentes (`tests/bootstrap-secrets.tests.ps1`)

19 blocos `It`, cobrindo:
- Migração v1→v2, import com dedupe, ordem rotação seedada
- Resolução de profile, listagem mascarada
- Placeholders ativos, MCPs opt-in
- VS Code GitHub MCP gating, Insiders path, paths nightly Roo/Cline
- BYOK env slots, escopo Gemini, redação em logs
- Manifesto de projeto > usuário, normalização permissions Claude
- Stubs de dual-boot (não relacionado a secrets — convive no mesmo arquivo)
- **Já existe**: "does not apply an invalid active credential" + "rotates a provider to the next valid credential only"

`bootstrap-secrets.performance.tests.ps1` tem 1 `It` apenas (normalização rápida para UI).

### Gaps reais para "rotação automática agendada" (escopo do plano)

| Gap | Status | Impacto |
|---|---|---|
| **Fila de rotação programática** (vs. ativação manual) | ❌ não existe | `Move-...ToNextCredential` é one-shot; não há `Get-Queue` / `Add-Item` / `Invoke-Item` separados |
| **Timeout por validador** | ⚠️ parcial — commit `6db98db` cita timeout, mas não está exposto como parâmetro de `Test-BootstrapSecretsProviderCredential` | Risco de hang citado no parecer |
| **Retry/backoff** | ❌ ausente | Falha de rede 1× = `state=failed` definitivo até próximo `-SecretsValidateAll` |
| **State machine documentada** | ❌ ausente | `Move-...ToNextCredential` mistura validação+ativação; transições implícitas |
| **Scheduler Windows (Task Scheduler)** | ❌ ausente | Sem `-RotateSecrets` flag; sem trigger temporal |
| **Log estruturado de eventos** (`rotation-events.jsonl`) | ❌ ausente | Logs vão para o log geral; sem campo dedicado consumível pela UI |
| **Notificação ao usuário** | ❌ ausente | Sem hook na UI; só lista mascarada |
| **`Register-BootstrapChange` em ativação/rotação** | ❌ ausente em `Set-BootstrapSecretsActiveCredential` e `Move-BootstrapSecretsToNextCredential` | Não-rollbackável; viola convenção do projeto |
| **Concorrência (lock no manifest)** | ⚠️ commit `b72a293` endureceu writes; falta validar lock cross-process | Race em rotação automática agendada |
| **Testes de rotação multi-credencial + falha parcial** | ⚠️ 2 testes cobrem happy + 1 caminho de falha; faltam: timeout, retry, concorrência, evento estruturado | TASK-006 ainda válido |

### Implicações para o plano

**Re-estimativa de TASK-002..TASK-007:**

| Task | Estimativa original | Re-estimativa | Razão |
|---|---|---|---|
| TASK-002 (state machine ADR) | 3h | 3h | sem mudança — ADR é greenfield |
| TASK-003 (worker de fila) | 8h | **10h** | precisa refatorar `Move-...ToNextCredential` em pedaços + adicionar `Register-BootstrapChange` retroativamente |
| TASK-004 (scheduler) | 4h | 4h | sem mudança |
| TASK-005 (notificação) | 3h | 3h | sem mudança |
| TASK-006 (testes) | 6h | **8h** | precisa cobrir lock cross-process + retry + timeout |
| TASK-007 (merge) | 1h | **3h** | branch é grande (32k linhas); rebase pode ter conflitos com `main` recente |

**Total Fase 1 secrets:** 27h → **31h**.

### Riscos descobertos

1. **A branch acumulou trabalho não-relacionado** (Steam Deck, AppTuning, UI hardening, API Center). Fechar TASK-007 mergeando tudo de uma vez é arriscado. **Recomendação:** após TASK-006, separar commits de rotação dos demais via cherry-pick em branch nova `feature/secrets-rotation-only`. Adicionar como **TASK-006a**.
2. **`Ensure-BootstrapSecrets` (linha 16878)** é o ponto único onde o broadcast acontece. Rotação automática precisa chamá-lo após mudança de `activeCredential`. Já é feito em `Invoke-BootstrapSecretsMode`; replicar no worker novo.
3. **`Set-BootstrapApiCredential` (19841) muta state e escreve disco diretamente**. Não chama `Register-BootstrapChange`. Antes de TASK-003, decidir se rotação automática usa a API helper ou o caminho `Move-...ToNextCredential`. **Recomendação:** worker usa as funções puras (sem I/O) e o próprio worker grava+registra mudança, mantendo testabilidade.

### Nova task derivada

#### TASK-006a: Isolar commits de rotação em branch limpa
- **status:** pending
- **depends_on:** [TASK-006]
- **estimated_hours:** 3
- **objetivo:** Criar `feature/secrets-rotation-only` com apenas os commits relevantes via cherry-pick; descartar mudanças misturadas.
- **passos:**
  1. `git checkout -b feature/secrets-rotation-only main`
  2. Cherry-pick seletivo (lista a definir ao chegar na task) — provavelmente: spec, função worker, scheduler, eventos, testes.
  3. Verificação: parse + Pester verde.
- **critério de aceite:** PR enxuto (<2k linhas) focado só em rotação.

### Verificação final

Executando `Invoke-Pester -Path .\tests\bootstrap-secrets.tests.ps1 -EnableExit` (Pester 3.4.0). Resultado registrado abaixo após o run.

**Resultado Pester:** `Passed: 18 Failed: 0 Skipped: 0 Pending: 0 Inconclusive: 0` (49.79s, Pester 3.4.0). Baseline verde — pode prosseguir para TASK-002.

---

## 7. Glossário de Sinais para Próximo Agente

| Sinal | Significado | Ação |
|---|---|---|
| `wip(TASK-NNN)` no log do git | Trabalho parcial commitado | Continue a partir da `task in_progress` |
| Branch ativa diferente de Estado de Execução | Estado desatualizado | Sincronize antes de codar |
| `Findings` ausente em TASK que depende de auditoria | Auditoria não rodou | Volte uma task |
| Pester falha em teste não relacionado | Regressão de outra task | Pare e investigue antes de prosseguir |
| `.bootstrap-tools/rotation-events.jsonl` com `failed` recente | Rotação real falhou | Investigar antes de mergear qualquer coisa em main |

---

**Fim do plano. Atualize seção 1 antes de fechar a sessão.**
---

## Atualizacao de Execucao - 2026-05-26

- **Agente:** Codex.
- **Status:** Roadmap suporte local robusto em Fase 1 parcial.
- **Implementado:** `doctor.secrets`, `doctor.aiUsagebar`, `secrets-doctor.json`, `ai-usagebar.json`, redacao de `api_key` inline e tokens (`ghp_`, `sk-`, `sk-or-`, `protectedData`, `.env` bruto).
- **Arquivos tocados:** `bootstrap-tools.ps1`, `tests/bootstrap-support-robustness.tests.ps1`, `AGENT_EXECUTION_PLAN.md`.
- **Verificacao verde:** parse all `.ps1`; PSScriptAnalyzer Severity Error; targeted Pester `tests/bootstrap-support-robustness.tests.ps1` 14/14; `install-cli.ps1 --tool ai-usagebar --validate --yes --no-admin`; `bootstrap-tools.ps1 -Doctor -DryRun -NonInteractive`; `bootstrap-tools.ps1 -SupportBundle -DryRun -NonInteractive`.
- **Bloqueio:** `tests\run-pester.ps1 -NoInstall` excedeu timeout de 10min sem resumo; nao marcar roadmap completo ate rerodar com timeout maior ou isolar hang.
- **Proxima task concreta:** Fase 2 WSL Repair Seguro com TDD.

---

## Atualizacao de Execucao - 2026-05-27

- **Agente:** Codex.
- **Status real:** Fases 1 a 6 entregues e revalidadas nesta worktree. Full Pester final verde.
- **Fase 1 fechada:** suite completa rerodada com timeout de 30min; `doctor.secrets`, `doctor.aiUsagebar` e SupportBundle redigido mantidos verdes.
- **Fase 2 entregue:** `doctor.wslRepair` com `REGDB_E_CLASSNOTREG`, `missingAppx`, `missingService`, `unknown`; WSL probe com timeout curto; RepairPlan `repair-wsl-registration`; bloqueio non-admin/noninteractive; bundle inclui `wsl-repair.json`.
- **Fase 3 entregue:** cobertura BAT/CLI para `bootstrap-ui.bat` e `install-cli.bat`; smoke sem stderr, pass-through e linhas legiveis.
- **Fase 4 entregue:** painel Saude como entrada operacional, cards WSL/winget/reboot/secrets/GitHub CLI/ai-usagebar/Steam Deck/rollback, acoes Doctor/Export bundle/RepairPlan/Copiar diagnostico e feedback por resultado.
- **Fase 5 entregue:** `durationMs` em doctor/checks/repairPlan/supportBundle; Audit corrigido para nao travar em scan recursivo de logs Codex; Audit default fechou em ~31s.
- **Fase 6 entregue:** `ReleasePack` com zip, `SHA256SUMS.txt`, `CHANGELOG.md`, `version.json`, `upgrade.ps1`; zip validado sem `.env`, `bootstrap-secrets`, `protectedData`, `ghp_`, `github_pat_`, `sk-`, `sk-or-`.
- **Comandos rodados finais:** parse all `.ps1` 121 arquivos ok; PSScriptAnalyzer Severity Error=0; `tests\run-pester.ps1 -NoInstall` Passed=392 Failed=0; `bootstrap-ui.bat -SmokeTest` exit 0; `safe-base -DryRun` exit 0; `-Audit -DryRun` exit 0; `-Doctor -DryRun` exit 0; `-SupportBundle -DryRun` exit 0.
- **Artefatos finais:** result JSON gravado para Doctor, SupportBundle, RepairPlan, Audit, safe-base e ReleasePack em `C:\Users\misae\AppData\Local\Temp\phasezero_final_9ffde2e4572a4e36b2f5b8f99d8c4d6a`.
- **Bloqueios reais:** nenhum bloqueio funcional restante. Host tem WSL com `LxssManager` ausente/restart requerido, mas Doctor/Audit nao travam e reportam acao recomendada.
- **Proxima task unica:** revisar diffs grandes e separar commits por escopo antes de PR/merge.

---

## Atualizacao de Execucao - 2026-05-30

- **Agente:** Codex.
- **Status real:** parecer Trae reconciliado com execucao segura; validacao completa verde.
- **Implementado/confirmado:** blocklist de ghost-recovery para runtimes criticos (`Microsoft.VCRedist.2015+.x64`, `Microsoft.VCRedist.2015+.x86`, `Microsoft.DirectX`, `ViGEm.ViGEmBus`); ProbePaths corrigidos para VC++ em `System32`, ViGEm em `System32\drivers`, ExplorerPatcher em `ep_setup.exe`; winget user-scope non-admin com timeout 300000ms e skip `no-applicable-installer` para `0x8A150010`; Rollback dry-run com `plannedActions` sem mutacao; UI LogTimer prioriza `result.json` pronto se polling do processo falhar; helper de testes mata subprocess tree em timeout.
- **TDD/targeted verdes:** `tests\resilience.tests.ps1` 89/89; `tests\bootstrap-ui-launcher.tests.ps1` 46/46; `tests\bootstrap-probe-paths.tests.ps1` 13/13; `tests\bootstrap-tools.profiles.tests.ps1` 23/23.
- **Validacao final:** parse all `.ps1` 122 arquivos OK; PSScriptAnalyzer tracked Severity Error=0 e warnings=704/705; `tests\run-pester.ps1 -NoInstall` Passed=413 Failed=0 Total=413 em 1093.9s; `bootstrap-ui.bat -SmokeTest` exit 0; `install-cli.ps1 --tool aionui --validate --yes --no-admin` exit 0; `install-cli.bat --tool ai-usagebar --validate --dry-run --yes` exit 0; `bootstrap-tools.ps1 -Doctor -DryRun -NonInteractive` exit 0; `-SupportBundle -DryRun -NonInteractive` exit 0; `-RepairPlan -DryRun -NonInteractive` exit 0; `-Audit -DryRun -NonInteractive` exit 0; `-Profile safe-base -DryRun -NonInteractive` exit 0.
- **AionUI neste host:** instalado em `C:\Users\misae\AppData\Local\Programs\AionUi\AionUi.exe`, versao `2.1.5.0`; smoke Start-Process OK, processo vivo e encerrado pelo teste. Doctor detectou env de `openai`, `anthropic`, `openrouter`, `deepseek`, sem expor valores; `configStatus=discovered-manual`, entao provider config automatica fica em fallback manual seguro por schema local nao documentado.
- **SupportBundle:** `C:\Users\misae\AppData\Local\Temp\phasezero-support_20260530_052854_15228_c8c0a7f7.zip`; entradas incluem `aionui.json`, `ai-usagebar.json`, `secrets-doctor.json`, `wsl-repair.json`, `repair-plan.json`; scan PS5 sem hits para `ghp_`, `github_pat_`, `sk-`, `sk-or-`, `sk-ant-`, `protectedData`, nomes de env sensiveis, `.env` bruto ou `bootstrap-secrets.json`.
- **Bloqueios reais:** host reporta WSL `RequiresRestart`/`LxssManager` ausente e alguns apps opcionais ausentes/ghost no Audit; nao bloqueiam Doctor/Audit/SupportBundle e geram JSON.
- **Proxima task unica:** revisar diff final, commitar sem `.trae/`, e push da branch `codex-bootstrap-secrets-rotation`.
