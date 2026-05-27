# PhaseZero

PhaseZero e um instalador e auditor Windows para pos-instalacao segura. O alvo minimo e maquina Windows limpa com Windows PowerShell 5.1. O projeto deve explicar escopo, escrever `result.json`, preservar logs e falhar com diagnostico acionavel.

## Principios de Produto

- Dry-run antes de mutacao real.
- Perfil default pequeno e seguro: `safe-base`.
- Perfil amplo somente por opt-in: `full-workstation`.
- Componentes isolados nao herdam perfil, HostHealth ou AppTuning por acidente.
- UI e CLI compartilham contrato de execucao, logs e resultado.
- Falha sem `result.json` e tratada como erro do produto.
- Reboot pendente bloqueia fluxos winget/MSI arriscados antes de mutar.
- Rollback e aplicado onde ha manifest seguro; apps instalados por terceiros podem exigir remocao manual.

## Requisitos

- Windows 10/11.
- Windows PowerShell 5.1.
- Sessao interativa para a UI WPF.
- Internet para bootstrap de App Installer/winget e pacotes online.
- Pester 3.4.0 para rodar a suite local. `tests\run-pester.ps1` detecta a versao exata e tenta instalar em `CurrentUser` quando ausente; use `-NoInstall` para bloquear rede/mutacao e receber erro instrutivo.

Sem winget em maquina limpa, o bootstrap tenta caminho seguro de App Installer oficial (`https://aka.ms/getwinget`) quando aplicavel. Se PATH/sessao ainda nao enxergar winget depois do bootstrap, a UI/CLI devem orientar logoff, nova sessao ou reboot em vez de falhar de modo opaco.

## Uso Seguro

UI:

```cmd
bootstrap-ui.bat
```

Smoke test da UI, sem abrir janela:

```cmd
cmd /c bootstrap-ui.bat -SmokeTest
```

CLI dry-run de componente isolado:

```powershell
.\bootstrap-tools.ps1 -Component notepadpp -DryRun -NonInteractive -HostHealth off -AppTuning off
```

Perfil seguro:

```powershell
.\bootstrap-tools.ps1 -Profile safe-base -DryRun -NonInteractive
```

Perfil beta publico:

```powershell
.\bootstrap-tools.ps1 -Profile public-beta -DryRun -NonInteractive
```

Perfil amplo, somente escolha explicita:

```powershell
.\bootstrap-tools.ps1 -Profile full-workstation -DryRun -NonInteractive
```

Auditoria:

```powershell
.\bootstrap-tools.ps1 -Audit -DryRun -NonInteractive
```

Diagnostico local:

```powershell
.\bootstrap-tools.ps1 -Doctor -DryRun -NonInteractive
.\bootstrap-tools.ps1 -SupportBundle -DryRun -NonInteractive
.\bootstrap-tools.ps1 -RepairPlan -DryRun -NonInteractive
```

`-Doctor` inclui `doctor.deck` com diagnostico read-only do Steam Deck quando aplicavel: hardware, AMD driver, bateria/power plan, display, input, streaming/conectividade e libraries Steam. `-SupportBundle` adiciona `deck-doctor.json`, `deck-power.json`, `deck-display.json` e `deck-libraries.json`; HTML bruto de `powercfg` nao entra no zip por padrao.

## Perfis

- `safe-base`: base pequena para maquina limpa. Inclui runtime/dev essencial e Notepad++. Nao inclui desktops de IA, containers, jogos, HostHealth ou AppTuning.
- `recommended`: alias seguro/compat para `safe-base`.
- `public-beta`: primeira instalacao confiavel; inclui base segura, PowerShell, PowerToys, Brave, VS Code, secrets e MCPs. Nao inclui WSL/Docker/IA desktop/gaming.
- `dev-ai`: pilha de IA/dev por escolha explicita.
- `full-workstation`: perfil amplo com stacks desktop, IA, containers, creator, social e utilitarios. Nunca deve ser default silencioso.
- `legacy`: compatibilidade com fluxo historico.

## Escopo UI/CLI

Quando usuario seleciona componente isolado, backend recebe somente o componente necessario:

```powershell
-Component notepadpp -HostHealth off -AppTuning off
```

O backend nao deve receber `-Profile recommended` nesse caso. Se perfis e componentes coexistem na UI, o botao principal exige confirmacao de escopo antes de executar:

- somente componentes selecionados;
- perfil atual + componentes;
- cancelar.

## Result JSON

Toda execucao deve deixar um `result.json` parseavel quando `ResultPath` existe ou quando o script escolhe caminho padrao. O envelope comum inclui:

- `status`: `success`, `warning`, `blocked` ou `error`;
- `exitCode`;
- `mode`;
- `artifactPaths.logPath`;
- `artifactPaths.resultPath`;
- `diagnostics[]`;
- `scope`;
- `rollback`;
- `auditSummary` e `auditResults[]` quando `mode = audit`.
- `doctor`, `supportBundle` e `repairPlan` quando os modos de suporte local forem usados.
- `doctor.deck` quando `mode = doctor` ou bundle de suporte gerar diagnostico Steam Deck.

UI e `install-cli.ps1` nao aceitam sucesso somente por exit code. Se processo elevado, crash fake ou backend morto nao escrever `result.json`, a camada chamadora cria fallback com stdout/stderr/log/result e acao recomendada.

## Auditoria

Severidades publicas:

- `Ready`
- `NeedsInstall`
- `NeedsRepair`
- `RequiresRestart`
- `ManualAction`
- `OptionalMissing`
- `UnsupportedAudit`

`UnsupportedAudit` nao entra em contagem critica. `Skipped` legado vira `UnsupportedAudit`. `GhostInstall` vira `NeedsRepair` quando ha reparo seguro; caso contrario, deve virar acao manual clara. Java valida JDK real por `javac.exe`/path de JDK, nao somente `java -version`. .NET SDK valida banda 8.x por `dotnet --list-sdks`.

## Logs e Artefatos

Locais comuns:

- `%USERPROFILE%\.bootstrap-tools\logs\`
- `%LOCALAPPDATA%\bootstrap-tools\logs\`
- `%TEMP%\bootstrap-tools\`

Campos importantes em falha:

- componente afetado;
- causa;
- `howToFix`;
- stdout/stderr quando houver processo filho;
- `rollback.available`;
- caminho de change manifest quando existir.

## Rollback e Limites

Rollback cobre mudancas registradas pelo projeto: registro, arquivos gerenciados, alguns servicos e exclusoes Defender controladas. Nao promete desfazer com seguranca todo pacote winget/npm/chocolatey/uv instalado fora do manifest. Quando rollback automatico nao e seguro, `result.json` deve marcar acao manual.

Limites atuais:

- alguns componentes ainda retornam `UnsupportedAudit` ate existir heuristica segura;
- alguns provedores/API exigem login, OAuth ou revisao manual;
- pacotes externos podem mudar IDs, instaladores e comportamento;
- WSL, MSI e winget podem exigir reboot antes de nova tentativa;
- UI WPF exige sessao desktop interativa.

## Verificacao Local

Parse PowerShell:

```powershell
$files = 'bootstrap-tools.ps1','bootstrap-ui.ps1','install-cli.ps1'
foreach ($f in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors) > $null
  if ($errors) { $errors | Format-List; exit 1 }
}
```

Contrato e dry-runs minimos:

```powershell
.\bootstrap-tools.ps1 -UiContractJson -NonInteractive | ConvertFrom-Json | Out-Null
.\bootstrap-tools.ps1 -Component notepadpp -DryRun -NonInteractive -HostHealth off -AppTuning off
.\bootstrap-tools.ps1 -Profile safe-base -DryRun -NonInteractive
.\bootstrap-tools.ps1 -Audit -DryRun -NonInteractive
cmd /c bootstrap-ui.bat -SmokeTest
```

Suite. Em maquina limpa, o runner prepara Pester 3.4.0 em `CurrentUser` com timeout e retry controlado:

```powershell
.\tests\run-pester.ps1
```

Suite sem instalar dependencia ausente:

```powershell
.\tests\run-pester.ps1 -NoInstall
```

## Seguranca

- Nao versionar `.bootstrap-tools/`, `.mcp.json`, logs, dumps ou manifests com credenciais.
- Credenciais locais ficam fora do Git.
- Tokens vazados fora do gerenciador de segredos devem ser rotacionados.
- Componentes `manual-required` explicam motivo e instrucao, sem marcar sucesso automatico.
