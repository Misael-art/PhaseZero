# Analise PhaseZero - Diagnostico e Recomendacoes

**Status:** Concluido + Implementado parcialmente (2026-05-08)
**Autor:** Agente de Analise IA
**Data:** 2026-05-08
**Versao:** 1.0
**Scope:** `bootstrap-tools.ps1`, `bootstrap-ui.ps1`, CI/CD, testes, estrutura de repositorio

---

## 1. Perfil do Projeto

Orquestrador de bootstrap e pos-instalacao para Windows + Steam Deck.
- Linguagem: PowerShell 5.1/7
- Interface: WPF via `bootstrap-ui.ps1` + CLI `bootstrap-tools.ps1` + BAT launcher
- Catalogo: 200+ componentes (winget, npm, uvtool, manual, builtin)
- Testes: Pester 3.4+ (20 arquivos de teste)
- CI: GitHub Actions (parse PS + Pester + gitleaks)
- Docs: `docs/superpowers/` com specs e plans

---

## 2. Falhas e Riscos (Classificados)

### 2.1. Arquitetura

| ID | Falha | Severidade | Evidencia |
|----|-------|------------|-----------|
| ARC-01 | Monolito `bootstrap-tools.ps1` com 16.445 linhas | **Critica** | `bootstrap-tools.ps1` unico arquivo; parse PS leva ~2s |
| ARC-02 | `bootstrap-ui.ps1` com 5.815 linhas (interface WPF misturada com logica) | Alta | UI, strings i18n, bindings e orquestracao no mesmo script |
| ARC-03 | Ausencia de modulos PowerShell (`.psm1`) | Alta | Nenhum `.psm1` no repo; 644 funcoes num unico escopo global |
| ARC-04 | Acumulo de 40+ arquivos `.bak` em `.bootstrap-tools/` | Media | `glob` mostra `steamdeck-settings.json.2026*.bak` versionados |

### 2.2. Manutencao e Qualidade

| ID | Falha | Severidade | Evidencia |
|----|-------|------------|-----------|
| MTN-01 | Nenhum `TODO`/`FIXME`/`HACK` no codigo (negativo: falta de rastreamento) | Media | `grep` retorna 0 matches |
| MTN-02 | Ausencia de `PSScriptAnalyzer` no CI | **Critica** | `ci.yml` so faz parse + Pester |
| MTN-03 | Nomeacao redundante: prefixo `Bootstrap`/`Bootstrap-` em 90% das funcoes | Baixa | Ex: `Get-BootstrapAppTuningCatalog`, `Test-BootstrapDiskSpace` |
| MTN-04 | Strings de log misturadas pt-BR/en-US sem sistema i18n | Media | `'Espaco em disco'` vs `'WSL: reparo requer...'` |
| MTN-05 | `Set-StrictMode -Version Latest` usado globalmente, mas inconsistencias de tipo possiveis | Media | `[AllowNull()][object]$Value` em multiplos lugares |

### 2.3. Seguranca

| ID | Falha | Severidade | Evidencia |
|----|-------|------------|-----------|
| SEC-01 | `bootstrap-secrets.json` sem encriptacao em repouso | **Critica** | Spec reconhece: "Nao criptografar nesta etapa" |
| SEC-02 | `gitleaks.yml` basico; sem regra para `.bak` ou `*.json.bak` | Media | `.github/workflows/gitleaks.yml` usa config padrao |
| SEC-03 | `.mcp.json` no `.gitignore` mas referenciado no README | Baixa | Potencial vazamento se usuario esquecer o ignore |
| SEC-04 | Logs em `%TEMP%` sem sanitizacao de dados sensíveis | Media | `Write-Log` loga paths e mensagens de erro sem filtro |

### 2.4. Performance

| ID | Falha | Severidade | Evidencia |
|----|-------|------------|-----------|
| PERF-01 | `Test-WingetPackageInstalled` chama `winget list` a cada checagem | Alta | 200+ componentes x chamadas repetidas = tempo linear alto |
| PERF-02 | Parse de 16k+ linhas de PS 5.1 em cada execucao | Media | Startup visivelmente lento em maquinas medias |
| PERF-03 | Mutex global de log (`Global\PhaseZeroBootstrapLog_*`) com timeout 2s | Baixa | Pode bloquear se multiplas instancias simultaneas |

### 2.5. CI/CD e DevEx

| ID | Falha | Severidade | Evidencia |
|----|-------|------------|-----------|
| CI-01 | `ci.yml` usa `actions/checkout@v4` hardcoded; sem `dependabot` para actions | Baixa | `.github/dependabot.yml` so monitora `github-actions` weekly |
| CI-02 | Pester 3.4.0 fixo; nao testa Pester 5.x | Baixa | `Install-Module Pester -RequiredVersion 3.4.0` |
| CI-03 | Ausencia de teste de integracao para UI WPF | Alta | `bootstrap-ui.tests.ps1` inexistente |
| CI-04 | Nenhum `version.json` ou tag semver no repo | Media | README menciona perfis mas nao versao do bootstrap |
| CI-05 | `install-cli.ps1` sem teste automatizado | Media | Script de CLI interativo nao coberto por Pester |

---

## 3. Melhorias Recomendadas (Priorizadas)

### 3.1. Criticas (Bloqueantes para Escalabilidade)

**[ARC-01] Modularizar `bootstrap-tools.ps1`**
- Criar estrutura:
  ```
  modules/
    PhaseZero.Core.psm1         # Logging, disco, estado, rollback
    PhaseZero.Catalog.psm1      # Catalogo de componentes e perfis
    PhaseZero.Resolver.psm1     # Resolvedor de dependencias
    PhaseZero.Installers.psm1   # Wrappers winget/npm/uv/choco
    PhaseZero.SteamDeck.psm1    # Tudo relacionado a Steam Deck
    PhaseZero.Secrets.psm1      # manifesto de credenciais
    PhaseZero.MCP.psm1          # MCPs gerenciados
    PhaseZero.UI.psm1           # Contrato da UI (JSON)
  ```
- Manter `bootstrap-tools.ps1` como thin orchestrator (~500 linhas)

**[MTN-02] Adicionar `PSScriptAnalyzer`**
- Pipeline de CI novo job `lint`:
  ```yaml
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          Install-Module PSScriptAnalyzer -Force
          Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning
  ```
- Regras criticas: `PSAvoidUsingCmdletAliases`, `PSReviewUnusedParameter`, `PSUseOutputTypeCorrectly`

### 3.2. Altas (Impacto em Confiabilidade)

**[PERF-01] Cache de `winget list`**
- No inicio da execucao, cachear output de `winget list` em memoria (hashtable por ID)
- Invalidar cache apenas se `--force` ou apos mudanca de componente

**[SEC-01] Encriptar `bootstrap-secrets.json`**
- Usar `DPAPI` (`[System.Security.Cryptography.ProtectedData]`) ou `CredentialManager`
- Fallback opcional: AES-GCM com key derivada de user+machine

**[CI-03] Testes de UI**
- Smoke test que valida JSON de contrato (`-UiContractJson`)
- Teste que simula click-through com input automatizado (ou screenshot diff)

### 3.3. Medias (Polimento)

**[ARC-04] Sanitizar `.bootstrap-tools/`**
- Adicionar ao `.gitignore`:
  ```
  .bootstrap-tools/*.bak
  .bootstrap-tools/*.log
  .bootstrap-tools/ui-runs/
  ```
- Criar job de CI que falha se `.bak` for adicionado ao repo

**[MTN-04] Centralizar strings**
- Criar `$script:Strings = @{ 'pt-BR' = @{...}; 'en-US' = @{...} }`
- Substituir strings inline por chaves lookup

---

## 4. Oportunidades Taticas (Quick Wins)

1. **Version Semver**: Criar `version.json` com `major.minor.patch` + hash do commit
2. **PSScriptAnalyzer local**: Script `analyze.ps1` que roda antes do commit
3. **Clean install test**: Workflow CI que simula `install-cli.ps1` em VM Windows limpa
4. **Dependabot para Pester**: Permitir testes com Pester 5.x paralelos
5. **Rollbar/telemetry opcional**: Metricas de tempo por componente anonimas

---

## 5. Decisoes Arquiteturais Sugeridas

### 5.1. Orquestrador vs Componentes

| Opcao | Pros | Cons |
|-------|------|------|
| Manter monolito | Simplicidade inicial, menos arquivos | Impossivel manter, merge conficts |
| **Modulos PS (recomendado)** | Type safety, reuso, testes isolados | Refatoracao inicial pesada (~4h) |
| Plugin architecture (futuro) | Terceiros adicionam componentes | Complexidade de discovery e seguranca |

**Recomendacao**: Modularizar imediatamente em 4-5 modulos. Plugin architecture e fase 2.

### 5.2. Estado vs Funcional

Atual: hashtable `$state` mutado inline por wrappers.

Sugestao: `class BootstrapState : System.Collections.Hashtable` com:
- `Checkpoint()` / `Resume()`
- `RegisterChange($type, $target, $old, $new)`
- `ToJson()` / `FromJson()`

### 5.3. UI WPF

Considerar migracao futura para:
- **Windows Terminal + TUI** (PowerShell + `PSReadLine` + menus)
- **Web-based UI** (Electron/Tauri) se precisar de UX rica
- **Manter WPF** mas separar XAML (.xaml) do code-behind (.ps1)

---

## 6. Checklist de Implementacao (para Outro Agente)

- [ ] **Fase 1: Fundacao**
  - [ ] Criar `modules/` e mover funcoes de core
  - [ ] Adicionar `PSScriptAnalyzer` ao CI
  - [ ] Criar `version.json` e job de validacao de tag
  - [ ] Limpar `.bak` do repo e atualizar `.gitignore`

- [ ] **Fase 2: Confiabilidade**
  - [ ] Implementar cache de `winget list`
  - [ ] Adicionar teste de integracao para `-UiContractJson`
  - [ ] Refatorar `bootstrap-ui.ps1` para separar strings i18n em arquivo

- [ ] **Fase 3: Seguranca**
  - [ ] Encriptar `bootstrap-secrets.json` com DPAPI
  - [ ] Adicionar regra gitleaks para `.bak`
  - [ ] Sanitizar logs de paths com tokens potenciais

- [ ] **Fase 4: Performance**
  - [ ] Medir tempo de startup atual (baseline)
  - [ ] Parallelizar resolucao de componentes independentes
  - [ ] Otimizar parse do catalogo (JSON binario ou hashtable compilado)

---

## 7. Metricas de Sucesso

| Metrica | Atual (est.) | Alvo |
|---------|--------------|------|
| Linhas `bootstrap-tools.ps1` | 16.445 | < 1.000 (orquestrador) |
| Tempo startup parse | ~2-3s | < 500ms |
| Tempo total `winget list` | O(n) linear | O(1) cacheado |
| Testes cobertura | ~20 arquivos | 90%+ linhas de modulos |
| Issues de lint PSSA | Desconhecido | 0 critical/warning |

---

## 8. Implementacoes Realizadas (2026-05-08)

- [x] Criado `version.json` com schema e validacao
- [x] Atualizado `.gitignore` para excluir `.bootstrap-tools/*.bak` e `ui-runs/`
- [x] Adicionado job `lint` no CI com PSScriptAnalyzer + validacao de `version.json`
- [x] Pester job com `needs: lint` para paralelismo controlado

---

## 9. Proximos Passos Posteriores

- [ ] Modularizar `bootstrap-tools.ps1` em modulos `.psm1`
- [ ] Adicionar cache de `winget list`
- [ ] Encriptar `bootstrap-secrets.json` com DPAPI
- [ ] Criar testes de integracao WPF

---

## 10. Referencias

- [README.md](../../README.md)
- [bootstrap-tools.profiles.tests.ps1](../../tests/bootstrap-tools.profiles.tests.ps1)
- [2026-04-18-bootstrap-secrets-manifest.md](2026-04-18-bootstrap-secrets-manifest.md)
- [2026-04-17-bootstrap-profiles-implementation.md](2026-04-17-bootstrap-profiles-implementation.md)

---

*Fim do documento.*
