# Bootstrap Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refatorar o `bootstrap-tools.ps1` para suportar perfis, componentes individuais, dependências e `dry-run`, preservando compatibilidade com o fluxo atual via perfil `legacy`.

**Architecture:** O script continuará único, mas a orquestração passará a ser dirigida por um catálogo declarativo de componentes e perfis. A lógica existente de instalação será reaproveitada por wrappers de componente, enquanto novos parâmetros e um resolvedor de dependências controlarão a seleção e a execução.

**Tech Stack:** PowerShell 5+/7+, WinGet, npm, uv, WSL, funções `Ensure-*` já presentes no repositório.

---

### Task 1: Criar testes de smoke para a nova interface

**Files:**
- Create: `C:\Users\misae\Documents\trae_projects\install_pos_install\tests\bootstrap-tools.profiles.tests.ps1`
- Modify: `C:\Users\misae\Documents\trae_projects\install_pos_install\bootstrap-tools.ps1`

- [ ] **Step 1: Escrever o teste que falha para listagem de perfis**

```powershell
$result = & powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -ListProfiles 2>&1
if ($LASTEXITCODE -ne 0) { throw "Expected success for -ListProfiles, got exit code $LASTEXITCODE`n$result" }
if (($result | Out-String) -notmatch 'legacy') { throw "Expected output to include legacy`n$result" }
if (($result | Out-String) -notmatch 'recommended') { throw "Expected output to include recommended`n$result" }
```

- [ ] **Step 2: Rodar o teste para confirmar que falha**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bootstrap-tools.profiles.tests.ps1
```

Expected: FAIL porque `-ListProfiles` ainda não existe.

- [ ] **Step 3: Escrever o teste que falha para resolução de componentes em dry-run**

```powershell
$result = & powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -Profile ai -Component docker -DryRun 2>&1
if ($LASTEXITCODE -ne 0) { throw "Expected success for dry-run resolution, got exit code $LASTEXITCODE`n$result" }
$text = $result | Out-String
foreach ($expected in @('node-core', 'python-core', 'wsl-core', 'docker', 'codex-cli')) {
    if ($text -notmatch [regex]::Escape($expected)) {
        throw "Expected dry-run output to include $expected`n$text"
    }
}
```

- [ ] **Step 4: Rodar o teste para confirmar que falha**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bootstrap-tools.profiles.tests.ps1
```

Expected: FAIL porque o script ainda não resolve perfis/componentes.

- [ ] **Step 5: Escrever o teste que falha para exclusão inválida de dependência**

```powershell
$result = & powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -Profile ai -Exclude node-core -DryRun 2>&1
if ($LASTEXITCODE -eq 0) { throw "Expected failure when excluding mandatory dependency`n$result" }
if (($result | Out-String) -notmatch 'depend') { throw "Expected dependency error message`n$result" }
```

- [ ] **Step 6: Rodar o teste para confirmar que falha**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bootstrap-tools.profiles.tests.ps1
```

Expected: FAIL porque o script ainda não valida exclusões.

### Task 2: Introduzir parâmetros, catálogo e resolvedor

**Files:**
- Modify: `C:\Users\misae\Documents\trae_projects\install_pos_install\bootstrap-tools.ps1`
- Test: `C:\Users\misae\Documents\trae_projects\install_pos_install\tests\bootstrap-tools.profiles.tests.ps1`

- [ ] **Step 1: Adicionar novos parâmetros ao script**

Adicionar no `param(...)`:

```powershell
[string[]]$Profile = @(),
[string[]]$Component = @(),
[string[]]$Exclude = @(),
[switch]$Interactive,
[switch]$ListProfiles,
[switch]$ListComponents,
[switch]$DryRun,
[switch]$NonInteractive,
[string]$WorkspaceRoot = 'F:\Steam\Steamapps'
```

- [ ] **Step 2: Criar o catálogo de componentes e perfis**

Adicionar funções:

```powershell
function Get-BootstrapComponentCatalog { }
function Get-BootstrapProfileCatalog { }
function Get-BootstrapSelection { }
function Resolve-BootstrapComponents { }
```

O catálogo deve conter pelo menos:

- `legacy`
- `base`
- `containers`
- `ai`
- `automation`
- `creator`
- `game-dev`
- `gaming`
- `workspace`
- `recommended`
- `full`

- [ ] **Step 3: Implementar saída de listagem**

Adicionar:

```powershell
function Show-BootstrapProfiles { }
function Show-BootstrapComponents { }
```

Comportamento:

- `-ListProfiles` imprime nome + descrição
- `-ListComponents` imprime nome + dependências
- ambos encerram o script com sucesso

- [ ] **Step 4: Implementar resolução de dependências e exclusões**

Adicionar validações:

- expandir perfis em componentes
- expandir dependências transitivas
- eliminar duplicatas preservando ordem
- abortar quando `-Exclude` remover dependência obrigatória

- [ ] **Step 5: Implementar saída de dry-run**

Quando `-DryRun` for usado, imprimir:

- perfis selecionados
- componentes solicitados
- componentes excluídos
- componentes resolvidos
- `CloneBaseDir` final
- `WorkspaceRoot` final

Sem executar instalações.

- [ ] **Step 6: Rodar os testes**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bootstrap-tools.profiles.tests.ps1
```

Expected: PASS

### Task 3: Encapsular a lógica existente em componentes executáveis

**Files:**
- Modify: `C:\Users\misae\Documents\trae_projects\install_pos_install\bootstrap-tools.ps1`
- Test: `C:\Users\misae\Documents\trae_projects\install_pos_install\tests\bootstrap-tools.profiles.tests.ps1`

- [ ] **Step 1: Criar estado compartilhado da execução**

Adicionar uma estrutura como:

```powershell
$state = @{
    Winget = $null
    GitInfo = $null
    NodeInfo = $null
    WorkspaceRoot = $WorkspaceRoot
    CloneBaseDir = $resolvedCloneBaseDir
}
```

- [ ] **Step 2: Criar wrappers de componente para a base atual**

Adicionar funções como:

```powershell
function Invoke-BootstrapComponent { param([string]$Name, [hashtable]$State) }
function Install-ComponentSystemCore { param([hashtable]$State) }
function Install-ComponentGitCore { param([hashtable]$State) }
function Install-ComponentNodeCore { param([hashtable]$State) }
function Install-ComponentPythonCore { param([hashtable]$State) }
```

Reaproveitar as funções `Ensure-*` já existentes.

- [ ] **Step 3: Mapear o perfil legacy para reproduzir o fluxo atual**

O perfil `legacy` deve executar em ordem equivalente ao script atual, incluindo:

- Git
- Node
- Java
- ImageMagick
- 7-Zip
- Python
- OpenCode
- Claude Code
- GitHub CLI
- apps desktop atuais
- `Ensure-WslUi`
- CLIs npm atuais
- defaults e hooks do Claude
- aider
- goose
- clone do `gemini-cli`

- [ ] **Step 4: Implementar componentes novos do catálogo**

Cobrir pelo menos:

- `git-lfs`
- `powershell`
- `terminal`
- `powertoys`
- `wsl-core`
- `docker`
- `ollama`
- `cherry-studio`
- `zed`
- `autohotkey`
- `blender`
- `ffmpeg`
- `n8n`
- `workspace-layout`

- [ ] **Step 5: Conectar resolvedor ao executor**

Trocar o bloco final linear por:

```powershell
$selection = Get-BootstrapSelection ...
$resolved = Resolve-BootstrapComponents ...
foreach ($componentName in $resolved) {
    Invoke-BootstrapComponent -Name $componentName -State $state
}
```

- [ ] **Step 6: Rodar smoke test de compatibilidade**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -Profile legacy -DryRun
```

Expected: lista coerente com o fluxo antigo.

### Task 4: Fechar UX, resumo e verificações finais

**Files:**
- Modify: `C:\Users\misae\Documents\trae_projects\install_pos_install\bootstrap-tools.ps1`
- Test: `C:\Users\misae\Documents\trae_projects\install_pos_install\tests\bootstrap-tools.profiles.tests.ps1`

- [ ] **Step 1: Implementar seleção interativa simples**

Adicionar menu com:

- `Recommended`
- `Legacy`
- `Full`
- `Custom by profile`
- `Custom by component`

Via `Read-Host`.

- [ ] **Step 2: Atualizar resumo final**

O resumo deve incluir:

- perfis aplicados
- componentes resolvidos
- `WorkspaceRoot`
- `CloneBaseDir`
- log path

- [ ] **Step 3: Executar os testes automatizados**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bootstrap-tools.profiles.tests.ps1
```

Expected: PASS

- [ ] **Step 4: Executar verificações manuais**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -ListProfiles
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -ListComponents
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -Profile recommended -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap-tools.ps1 -Component docker,ollama,ffmpeg -DryRun
```

Expected:

- todos os comandos com saída legível
- dependências visíveis
- sem instalações reais em `-DryRun`

- [ ] **Step 5: Registrar limitações encontradas**

Se algum pacote `winget` estiver indisponível no ambiente atual, deixar mensagem de aviso no código e no resumo final, sem quebrar os demais perfis.
