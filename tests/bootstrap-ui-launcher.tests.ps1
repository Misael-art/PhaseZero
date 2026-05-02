$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$uiScriptPath = Join-Path $repoRoot 'bootstrap-ui.ps1'

function New-TestDataRoot {
    return (Join-Path $env:TEMP ("bootstrap_ui_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Remove-TestDataRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Microsoft.PowerShell.Management\Test-Path $Path) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Bootstrap UI launcher' {
    BeforeEach {
        $script:TestDataRoot = New-TestDataRoot
    }

    AfterEach {
        Remove-TestDataRoot -Path $script:TestDataRoot
        Remove-Variable -Scope Script -Name TestDataRoot -ErrorAction SilentlyContinue
    }

    It 'supports smoke test execution from Windows PowerShell file mode' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $uiStatePath = Join-Path $script:TestDataRoot 'ui-state.json'
        $uiLogPath = Join-Path $script:TestDataRoot 'bootstrap-ui.log'

        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $uiScriptPath -UiStatePath $uiStatePath -UiLogPath $uiLogPath -SmokeTest 2>&1
        $exitCode = $LASTEXITCODE
        $text = ((@($output) -join [Environment]::NewLine)).Trim()

        $exitCode | Should Be 0
        ([string]::IsNullOrWhiteSpace($text)) | Should Be $false

        $result = $text | ConvertFrom-Json -ErrorAction Stop
        (@($result.pages) -contains 'welcome') | Should Be $true
        (@($result.pages) -contains 'app-tuning') | Should Be $true
        (@($result.pages) -contains 'api-center') | Should Be $true
        (@($result.pages) -contains 'api-catalog') | Should Be $true
        (@($result.languages) -contains 'pt-BR') | Should Be $true
        $result.statePath | Should Be $uiStatePath
        (Test-Path $uiStatePath) | Should Be $true
    }

    It 'keeps the embedded XAML parseable' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $match = [regex]::Match($raw, '(?s)\[xml\]\$xaml = @''\r?\n(.*?)\r?\n''@')

        $match.Success | Should Be $true
        { [xml]$null = $match.Groups[1].Value } | Should Not Throw
    }

    It 'loads the embedded XAML with the WPF runtime' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script = @"
`$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace(`$env:WINDIR) -and -not [string]::IsNullOrWhiteSpace(`$env:SystemRoot)) { `$env:WINDIR = `$env:SystemRoot }
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
`$raw = Get-Content -Path '$uiScriptPath' -Raw
`$match = [regex]::Match(`$raw, '(?s)\[xml\]\`$xaml = @''\r?\n(.*?)\r?\n''@')
if (-not `$match.Success) { throw 'XAML block not found' }
`$reader = New-Object System.Xml.XmlNodeReader ([xml]`$match.Groups[1].Value)
`$null = [Windows.Markup.XamlReader]::Load(`$reader)
'WPF_XAML_OK'
"@

        $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -STA -Command $script

        (@($output) -join [Environment]::NewLine).Trim() | Should Be 'WPF_XAML_OK'
    }

    It 'keeps grid and dropdown text readable in the dark theme' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'SystemColors\.WindowBrushKey'
        $raw | Should Match 'SystemColors\.WindowTextBrushKey'
        $raw | Should Match 'SystemColors\.HighlightTextBrushKey'
        $raw | Should Match 'TargetType="ListBoxItem"'
        $raw | Should Match 'TargetType="ComboBoxItem"'
        $raw | Should Match 'TargetType="DataGridColumnHeader"'
        $raw | Should Match 'TargetType="DataGridCell"'
        $raw | Should Match 'SelectionBrush'
        $raw | Should Match 'CaretBrush'
        $raw | Should Not Match 'LightSlateGray'
    }

    It 'exposes unknown external display classification actions' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'PendingExternalStatusLabel'
        $raw | Should Match 'ClassifyMonitorButton'
        $raw | Should Match 'ClassifyTvButton'
        $raw | Should Match 'Monitor/Dev'
        $raw | Should Match 'TV/Game'
    }

    It 'guards run execution against duplicate starts and missing result files' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Complete-RunExecutionWithoutResult'
        $raw | Should Match '\$ui\.RunProcess -and -not \$ui\.RunProcess\.HasExited'
        $raw | Should Match '\$ui\.StartRunButton\.IsEnabled = \$false'
        $raw | Should Match '\$ui\.StartRunButton\.IsEnabled = \$true'
        $raw | Should Match 'fallbackResult'
        $raw | Should Match 'Backend saiu sem result\.json'
    }

    It 'constrains Steam Deck monitor mode editing to supported modes' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        ([regex]::Matches($raw, 'DataGridComboBoxColumn Header="Perfil"').Count -ge 2) | Should Be $true
        $raw | Should Match 'HANDHELD'
        $raw | Should Match 'DOCKED_MONITOR'
        $raw | Should Match 'DOCKED_TV'
        $raw | Should Match 'Validate-SteamDeckGridModeRows'
    }

    It 'lists the internal Steam Deck display with primary flag and real status columns' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Get-UiSteamDeckProfileRows'
        $raw | Should Match 'target = ''internal'''
        $raw | Should Match 'Header="Principal"'
        $raw | Should Match 'Header="Status"'
        $raw | Should Match 'desativado: so desktop externo'
    }

    It 'exposes configurable Windows display modes with extend as the safe default' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'SteamDeckDisplayModes'
        $raw | Should Match '<sys:String>extend</sys:String>'
        $raw | Should Match '<sys:String>internal</sys:String>'
        $raw | Should Match '<sys:String>external</sys:String>'
        $raw | Should Match '<sys:String>clone</sys:String>'
        $raw | Should Match '\$settings\[''displayMode''\] = \$displayMode'
    }

    It 'keeps API organization and project reference separate' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'ApiProjectRefTextBox'
        $raw | Should Match 'projectRef = \$ui\.ApiProjectRefTextBox\.Text\.Trim\(\)'
        $raw | Should Not Match 'projectRef = \$ui\.ApiOrganizationTextBox\.Text\.Trim\(\)'
    }

    It 'exposes a full API key catalog page with requested columns' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'ApiCatalogButton'
        $raw | Should Match 'PageApiCatalog'
        $raw | Should Match 'ApiFullCatalogGrid'
        $raw | Should Match 'Refresh-ApiCatalogControls'
        foreach ($header in @('Ja possui','Quantidade','Configuradas','Provedor','O que faz','Voce vai precisar','Criar Chave','Ajuda')) {
            $raw | Should Match ([regex]::Escape(('Header="{0}"' -f $header)))
        }
    }

    It 'exposes AppTuning page with category and item selection controls' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match '<ScrollViewer x:Name="PageAppTuning"'
        $raw | Should Match 'AppTuningModeCombo'
        $raw | Should Match 'AppTuningSearchBox'
        $raw | Should Match 'AppTuningStatusFilterCombo'
        $raw | Should Match 'AppTuningCategoryList'
        $raw | Should Match 'AppTuningItemsGrid'
        $raw | Should Match 'Refresh-AppTuningControls'
        foreach ($header in @('Ativo','Categoria','App','Otimizacao','Perfil','Risco','Instalado','Configurado','Atualizado','Admin')) {
            $raw | Should Match ([regex]::Escape(('Header="{0}"' -f $header)))
        }
        foreach ($buttonName in @('AppTuningRecommendedButton','AppTuningMarkCategoryButton','AppTuningClearCategoryButton','AppTuningAuditButton','AppTuningInstallButton','AppTuningConfigureButton','AppTuningUpdateButton')) {
            $raw | Should Match $buttonName
        }
        $raw | Should Match 'Get-BootstrapAppTuningStatusRows'
        $raw | Should Not Match 'Apps sob demanda'
        $raw | Should Match 'Invoke-AppTuningSingleRowAction'
        $raw | Should Match 'Add_MouseDoubleClick'
    }

    It 'exposes Windows Boot Manager controls beyond GRUB detection' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        foreach ($name in @('WindowsBootEntriesGrid','WindowsBootDefaultCombo','WindowsBootTimeoutTextBox','ApplyWindowsBootButton','BackupWindowsBootButton')) {
            $raw | Should Match $name
        }
        $raw | Should Match 'Get-BootstrapWindowsBootManagerState'
        $raw | Should Match 'Set-BootstrapWindowsBootManager'
    }

    It 'persists AppTuning state fields and passes them to preview/backend' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        foreach ($stateField in @('appTuningMode','selectedAppTuningCategories','selectedAppTuningItems','excludedAppTuningItems')) {
            $raw | Should Match $stateField
        }
        $raw | Should Match '-RequestedAppTuningMode'
        $raw | Should Match '-AppTuningCategory'
        $raw | Should Match '-ExcludeAppTuningItem'
    }

    It 'loads ordered dictionary rows into WPF grids' {
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace(`$env:WINDIR) -and -not [string]::IsNullOrWhiteSpace(`$env:SystemRoot)) { `$env:WINDIR = `$env:SystemRoot }
Add-Type -AssemblyName PresentationFramework
`$raw = Get-Content -Path '$uiScriptPath' -Raw
`$tokens = `$null
`$errors = `$null
`$ast = [System.Management.Automation.Language.Parser]::ParseInput(`$raw, [ref]`$tokens, [ref]`$errors)
if (`$errors.Count -gt 0) { throw (`$errors | Out-String) }
`$functionAst = `$ast.Find({ param(`$node) `$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and `$node.Name -eq 'Load-WpfGridRows' }, `$true)
if (-not `$functionAst) { throw 'Load-WpfGridRows not found' }
Invoke-Expression `$functionAst.Extent.Text
`$grid = New-Object System.Windows.Controls.DataGrid
Load-WpfGridRows -Grid `$grid -Items @([ordered]@{ provider = 'OpenAI'; total = '1' }) -Columns @('provider', 'total')
`$row = `$grid.ItemsSource[0].Row
('{0}|{1}' -f [string]`$row['provider'], [string]`$row['total'])
"@

        $output = & $powershellExe -NoProfile -STA -Command $script

        (@($output) -join [Environment]::NewLine).Trim() | Should Be 'OpenAI|1'
    }

    It 'anchors API credentials and Steam Deck monitor grids at the top of their cards' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match '(?s)<Border Grid\.Column="0" Style="\{StaticResource Card\}">\s*<StackPanel>\s*<TextBlock x:Name="ApiCredentialsLabel"'
        $raw | Should Match '(?s)<TextBlock x:Name="MonitorProfilesLabel"[^>]+/>\s*<DataGrid\s+x:Name="MonitorProfilesGrid"'
        $raw | Should Match '(?s)<TextBlock x:Name="MonitorFamiliesLabel"[^>]+/>\s*<DataGrid\s+x:Name="MonitorFamiliesGrid"'
    }

    It 'shows profile-resolved components as checked in the install column' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Match 'Get-UiResolvedComponentNameSet'
        $raw | Should Match 'resolvedComponentLookup'
        $raw | Should Match '\$cb\.IsChecked = \(\(\$isExplicitComponent -or \$isResolvedComponent\) -and -not \$isExcludedComponent\)'
        $raw | Should Match 'Desmarcar item vindo de perfil adiciona em Nao instalar'
    }

    It 'does not ship known mojibake in visible UI strings' {
        $raw = Get-Content -Path $uiScriptPath -Raw

        $raw | Should Not Match 'sesses|genrico|Resoluo|Validao|Execuo|Reviso|Relatrios|manuteno'
    }

    It 'runs the batch launcher smoke test without stderr noise' {
        $stdoutPath = Join-Path $script:TestDataRoot 'stdout.txt'
        $stderrPath = Join-Path $script:TestDataRoot 'stderr.txt'
        $command = ('.\bootstrap-ui.bat -SmokeTest 1> "{0}" 2> "{1}"' -f $stdoutPath, $stderrPath)

        $null = New-Item -Path $script:TestDataRoot -ItemType Directory -Force

        Push-Location $repoRoot
        try {
            & cmd /c $command | Out-Null
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $exitCode | Should Be 0

        $stdout = ''
        if (Test-Path $stdoutPath) {
            $stdout = (Get-Content -Path $stdoutPath -Raw)
        }

        $stderr = ''
        if (Test-Path $stderrPath) {
            $stderr = (Get-Content -Path $stderrPath -Raw)
        }

        $stdout | Should Match '"pages"'
        ([string]::IsNullOrWhiteSpace($stderr)) | Should Be $true
    }

    It 'maps every direct UI event handler target before startup wiring' {
        $raw = Get-Content -Path $uiScriptPath -Raw
        $assigned = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($match in [regex]::Matches($raw, '(?m)^\s*(\w+)\s*=\s*\(Get-Control\s+''([^'']+)''\)')) {
            [void]$assigned.Add($match.Groups[1].Value)
        }

        foreach ($match in [regex]::Matches($raw, '\$ui\.(\w+)\.Add_')) {
            $target = $match.Groups[1].Value
            ($assigned.Contains($target) -or $target -in @('LogTimer')) | Should Be $true
        }
    }
}
