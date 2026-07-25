# PR6 (Windows) — escopo decidido

Entregável da **correção 3**. A pergunta era: as três sub-tarefas (A) `result.json`
no arranque, (B) `manual-required` deixa de bloquear `safe-base`, (C) UTF-8
consistente nos logs — cabem num PR só ou precisam de split, já que **A é
pré-requisito de B**?

## Decisão

**PR único, e pequeno.** A dependência A→B não se materializa porque **A, B e C
já estão implementados**. `plans/install-errors-analysis.md` está desatualizado
em relação ao código: descreve um estado de 2026-05-01 que não é mais o atual.

O PR6 deixa de ser um PR de feature e vira **um PR de verificação + um
resíduo**. Não há nada a sequenciar.

## Evidência, sub-tarefa a sub-tarefa

### (A) `result.json` no arranque do backend — **já feito**

A análise afirma que um erro antes de `Write-Log` deixa a UI sem `result.json`.
O código atual cobre isso em três camadas:

| Camada | Onde | O que faz |
|---|---|---|
| Fallback de path | `bootstrap-tools.ps1:82` | `$script:ResultPath` recebe `%TEMP%\bootstrap-tools_<RunId>.result.json` quando o chamador não passa `-ResultPath` — o path existe antes de qualquer operação |
| `catch` de topo | `bootstrap-tools.ps1:36388` (`phase = 'top-level'`) | Todo o pipeline está dentro de um `try`; qualquer exceção não tratada escreve o result de erro via `Write-BootstrapExecutionErrorResultFromRecord` |
| `catch` por modo | doctor, drift-check, support-bundle, ai-config-doctor, legacy-flow | Cada modo tem o seu próprio `catch` com `phase` nomeada |

E o caso que o backend **não consegue** cobrir — falha de *parameter binding*,
em que o PowerShell encerra antes de executar qualquer linha do script — é
tratado do lado do launcher: `Complete-RunExecutionWithoutResult`
(`bootstrap-ui.ps1:6578`) chama `Write-UiFallbackResult`, que sintetiza um
`result.json` com o exit code e, quando o backend rodou elevado, acrescenta a
dica `"Processo elevado encerrou antes do backend inicializar"`.

Não há lacuna. A UI nunca fica sem result.

### (B) `manual-required` não bloqueia mais — **já feito**

A análise diz que `google-app-desktop` está no perfil `base` e derruba a
instalação. Estado atual:

- O switch `-SkipManualRequirements` existe (`bootstrap-tools.ps1:50`), é
  promovido a `$script:SkipManualRequirements` (linha 90) e entra na decisão de
  bloqueio em `$wouldBlock` (linha 3205), junto de `-IgnoreManualRequirements`.
- `google-app-desktop` é declarado com `-Optional $true`
  (`bootstrap-tools.ps1:15971`), e `Ensure-BootstrapManualRequirement` só
  lança quando o componente **não** é opcional (linha 15474).
- O componente **não está mais em `base`**. Aparece só em `legacy` (linha
  16256) e `utilities` (linha 16274).

Ou seja: `safe-base` não tem como ser bloqueado por dependência manual. O
opt-in que a análise pedia já é o comportamento.

### (C) UTF-8 consistente — **quase feito; um resíduo, corrigido aqui**

- `debug-ui.ps1` já passa `-Encoding utf8` em todas as escritas (linhas 5-11);
  a análise descrevia o oposto.
- `Set-Content` / `Add-Content` sem `-Encoding`: nenhum. As duas ocorrências
  que o grep acha são nomes numa lista de cmdlets em
  `Reset-BootstrapFileCmdlets`, não escritas.
- **Resíduo real, corrigido neste PR**: o launcher gerado por
  `ai-memory-sync-launcher.ps1` (here-string em `bootstrap-tools.ps1:22692-22697`)
  escrevia o próprio log com `Out-File` sem encoding — UTF-16 LE com BOM, o
  bug exato que a análise descreve, sobrevivendo num script *gerado* e por isso
  invisível ao grep casual. Agora força `-Encoding utf8`.

Depois desta correção: **zero** escritas de arquivo sem encoding explícito em
`bootstrap-tools.ps1` e `bootstrap-ui.ps1`.

## Escopo final do PR6

| Item | Ação |
|---|---|
| (A) result.json no arranque | Nenhuma. Verificado e documentado acima. |
| (B) manual-required opt-in | Nenhuma. Verificado e documentado acima. |
| (C) UTF-8 nos logs | 3 linhas: `-Encoding utf8` no launcher gerado. |
| `plans/install-errors-analysis.md` | Marcar como histórico — descreve um estado já superado. Não apagar: é o registro de por que essas defesas existem. |

**Split? Não.** Um PR de três linhas mais este documento.

## O que NÃO foi verificado (e por quê)

As mudanças deste PR **não foram executadas nem testadas**. O ambiente de
trabalho é Linux (Manjaro) e não tem PowerShell instalado:

```
$ command -v pwsh powershell
(nada)
```

Portanto **não** rodei:

- `[Parser]::ParseFile` sobre `bootstrap-tools.ps1` / `bootstrap-ui.ps1`
- `Invoke-Pester -Path .\tests` com Pester 3.4.0
- `bootstrap-ui.bat -SmokeTest`

A alteração é de baixo risco (adição de `-Encoding utf8` a três `Out-File`
dentro de uma here-string, sem mudar a estrutura da string), mas **isso é
argumento, não evidência**. Rode a CI do Windows antes de fazer merge:

```powershell
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\bootstrap-tools.ps1), [ref]$tokens, [ref]$errors); $errors | Format-List
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Path .\tests -EnableExit
```

## Falhas de teste que a análise reporta e este PR não resolve

`plans/install-errors-analysis.md` cita duas asserções falhando em
`tests/bootstrap-ui-launcher.tests.ps1` (linhas 76 e 210). **Não verifiquei se
ainda falham** — sem PowerShell, não há como executar. Fica como item aberto,
não como item resolvido.
