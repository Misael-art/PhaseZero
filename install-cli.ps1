#Requires -Version 5.1
<#
.SYNOPSIS
    PhaseZero Bootstrap - instalador CLI.
.DESCRIPTION
    Fluxo legado de perfis continua. Fluxo AI tools aceita flags GNU-style:
    --tool, --all-ai-tools, --install, --validate, --configure, --start, --uninstall, --dry-run,
    --app, --component, --config, --list-apps, --list-configs, --list-tools, --yes, --no-admin,
    --install-root, --result-path e --log-path.
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [Console]::OutputEncoding
try { [Console]::Title = 'PhaseZero Bootstrap - CLI Installer' } catch { }

function Write-CliOut {
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Text,
        [Parameter(Position = 1)][System.ConsoleColor]$ForegroundColor
    )
    if ($ForegroundColor -ne $null) {
        try {
            $prev = [Console]::ForegroundColor
            [Console]::ForegroundColor = $ForegroundColor
            [Console]::WriteLine($Text)
            [Console]::ForegroundColor = $prev
            return
        } catch {
        }
    }
    [Console]::WriteLine($Text)
}

$ToolsPs1 = Join-Path $PSScriptRoot 'bootstrap-tools.ps1'

function New-CliOptions {
    return [ordered]@{
        Profile        = ''
        NonInteractive = $false
        SkipDryRun     = $false
        ListProfiles   = $false
        ListApps       = $false
        ListConfigs    = $false
        ListTools      = $false
        ListItems      = $false
        Tool           = @()
        AllAiTools     = $false
        Item           = @()
        App            = @()
        Component      = @()
        Config         = @()
        ConfigCategory = @()
        ExcludeConfig  = @()
        Install        = $false
        Validate       = $false
        Configure      = $false
        Start          = $false
        Uninstall      = $false
        FactoryReset   = $false
        ExportConfig   = ''
        ImportConfig   = ''
        Batch          = ''
        IncludeSecrets = $false
        InstallWebapps = $false
        RepairMcp      = $false
        DriftCheck     = $false
        DryRun         = $false
        Yes            = $false
        NoAdmin        = $false
        BackendTimeoutMs = 0
        InstallRoot    = ''
        ResultPath     = ''
        LogPath        = ''
        Help           = $false
    }
}

function ConvertTo-CliKey {
    param([Parameter(Mandatory = $true)][string]$Token)
    return (($Token.TrimStart('-','/')) -replace '-', '').ToLowerInvariant()
}

function Test-CliTokenLooksLikeOption {
    param([AllowNull()][string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    return ([string]$Token -match '^(--?|/)[A-Za-z][A-Za-z0-9-]*$')
}

function ConvertTo-CliTimeoutMs {
    param(
        [AllowNull()][string]$Value,
        [string]$OptionName = 'timeout'
    )

    $parsed = 0
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [int]::TryParse([string]$Value, [ref]$parsed)) {
        throw "Valor invalido para ${OptionName}: '$Value'. Use milissegundos inteiros."
    }
    if ($parsed -lt 60000 -or $parsed -gt 86400000) {
        throw "Valor invalido para ${OptionName}: $parsed. Use entre 60000 e 86400000 ms."
    }
    return $parsed
}

function Get-CliRawOptionValue {
    param(
        [string[]]$Tokens,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $wanted = @{}
    foreach ($name in @($Names)) {
        $wanted[(ConvertTo-CliKey -Token $name)] = $true
    }

    for ($i = 0; $i -lt @($Tokens).Count; $i++) {
        $token = [string]$Tokens[$i]
        if ($token -match '^(--?[^=]+)=(.*)$') {
            $key = ConvertTo-CliKey -Token $matches[1]
            if ($wanted.ContainsKey($key)) { return [string]$matches[2] }
            continue
        }
        if ($token -match '^[-/]') {
            $key = ConvertTo-CliKey -Token $token
            if ($wanted.ContainsKey($key) -and (($i + 1) -lt @($Tokens).Count)) {
                $candidate = [string]$Tokens[$i + 1]
                if (-not (Test-CliTokenLooksLikeOption -Token $candidate)) { return $candidate }
            }
        }
    }
    return ''
}

function Read-CliRequiredOptionValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][ref]$Index,
        [Parameter(Mandatory = $true)][string]$OptionName
    )

    $next = [int]$Index.Value + 1
    if ($next -ge @($Tokens).Count) {
        throw "Valor ausente para $OptionName."
    }
    $candidate = [string]$Tokens[$next]
    if (Test-CliTokenLooksLikeOption -Token $candidate) {
        throw "Valor ausente para $OptionName."
    }
    $Index.Value = $next
    return $candidate
}

function Read-CliArgs {
    param([string[]]$Tokens)
    $opts = New-CliOptions
    for ($i = 0; $i -lt @($Tokens).Count; $i++) {
        $token = [string]$Tokens[$i]
        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        if ($token -match '^(--?[^=]+)=(.*)$') {
            $key = ConvertTo-CliKey -Token $matches[1]
            $value = [string]$matches[2]
        } else {
            $key = if ($token -match '^[-/]') { ConvertTo-CliKey -Token $token } else { '' }
            $value = $null
        }

        switch ($key) {
            'profile' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                $opts.Profile = $value
            }
            'noninteractive' { $opts.NonInteractive = $true }
            'skipdryrun' { $opts.SkipDryRun = $true }
            'listprofiles' { $opts.ListProfiles = $true }
            'listapps' { $opts.ListApps = $true }
            'listapp' { $opts.ListApps = $true }
            'listconfigs' { $opts.ListConfigs = $true }
            'listconfig' { $opts.ListConfigs = $true }
            'listtools' { $opts.ListTools = $true }
            'listtool' { $opts.ListTools = $true }
            'listaitools' { $opts.ListTools = $true }
            'listaitool' { $opts.ListTools = $true }
            'listitems' { $opts.ListItems = $true }
            'listitem' { $opts.ListItems = $true }
            'tool' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.Tool += @($value) }
            }
            'allaitools' { $opts.AllAiTools = $true }
            'item' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.Item += @($value) }
            }
            'app' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.App += @($value) }
            }
            'component' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.Component += @($value) }
            }
            'config' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.Config += @($value) }
            }
            'configuration' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.Config += @($value) }
            }
            'apptuningitem' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.Config += @($value) }
            }
            'configcategory' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.ConfigCategory += @($value) }
            }
            'apptuningcategory' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.ConfigCategory += @($value) }
            }
            'excludeconfig' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.ExcludeConfig += @($value) }
            }
            'excludeapptuningitem' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                if (-not [string]::IsNullOrWhiteSpace($value)) { $opts.ExcludeConfig += @($value) }
            }
            'install' { $opts.Install = $true }
            'validate' { $opts.Validate = $true }
            'configure' { $opts.Configure = $true }
            'start' { $opts.Start = $true }
            'uninstall' { $opts.Uninstall = $true }
            'factoryreset' { $opts.FactoryReset = $true }
            'resetdefault' { $opts.FactoryReset = $true }
            'exportconfig' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                $opts.ExportConfig = $value
            }
            'importconfig' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                $opts.ImportConfig = $value
            }
            'batch' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                $opts.Batch = $value
            }
            'includesecrets' { $opts.IncludeSecrets = $true }
            'installwebapps' { $opts.InstallWebapps = $true }
            'repair-mcp' { $opts.RepairMcp = $true }
            'repairmcp' { $opts.RepairMcp = $true }
            'drift-check' { $opts.DriftCheck = $true }
            'driftcheck' { $opts.DriftCheck = $true }
            'dryrun' { $opts.DryRun = $true }
            'yes' { $opts.Yes = $true }
            'y' { $opts.Yes = $true }
            'noadmin' { $opts.NoAdmin = $true }
            'backendtimeoutms' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                $opts.BackendTimeoutMs = ConvertTo-CliTimeoutMs -Value $value -OptionName $token
            }
            'installroot' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                $opts.InstallRoot = $value
            }
            'resultpath' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                $opts.ResultPath = $value
            }
            'logpath' {
                if ($null -eq $value) { $value = Read-CliRequiredOptionValue -Tokens $Tokens -Index ([ref]$i) -OptionName $token }
                $opts.LogPath = $value
            }
            'help' { $opts.Help = $true }
            'h' { $opts.Help = $true }
            '' {
                if ([string]::IsNullOrWhiteSpace([string]$opts.Profile)) { $opts.Profile = $token }
            }
            default {
                throw "Argumento desconhecido: $token"
            }
        }
    }
    return $opts
}

function Pause {
    # Override do Pause nativo: em modo automacao (--yes/--non-interactive) ou com stdin
    # redirecionado/sem console, nunca bloquear esperando tecla (evita travar CLI/testes/CI).
    if ($script:Options -and (([bool]$script:Options.NonInteractive) -or ([bool]$script:Options.Yes))) { return }
    try { if ([Console]::IsInputRedirected) { return } } catch { return }
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch {
        try { Read-Host | Out-Null } catch { }
    }
}

function Write-Header {
    param([string]$Text)
    Write-CliOut ''
    Write-CliOut ('=' * 60) Cyan
    Write-CliOut "  $Text"
    Write-CliOut ('=' * 60) Cyan
    Write-CliOut ''
}

function Write-CliUsage {
    Write-CliOut ''
    Write-CliOut 'PhaseZero Bootstrap - CLI'
    Write-CliOut ''
    Write-CliOut 'Perfis:'
    Write-CliOut '  install-cli.bat -ListProfiles'
    Write-CliOut '  install-cli.bat -Profile safe-base -DryRun'
    Write-CliOut ''
    Write-CliOut 'Apps individuais:'
    Write-CliOut '  install-cli.bat --list-items'
    Write-CliOut '  install-cli.bat --list-apps'
    Write-CliOut '  install-cli.bat --item traefik --dry-run --yes'
    Write-CliOut '  install-cli.bat --app app-zen-browser --dry-run --yes'
    Write-CliOut '  install-cli.bat --app app-zen-browser --yes'
    Write-CliOut ''
    Write-CliOut 'Configuracoes individuais:'
    Write-CliOut '  install-cli.bat --list-configs'
    Write-CliOut '  install-cli.bat --config zen-browser-privacy-prefs --dry-run --yes'
    Write-CliOut '  install-cli.bat --config zen-browser-privacy-prefs --yes'
    Write-CliOut ''
    Write-CliOut 'AI tools:'
    Write-CliOut '  install-cli.bat --list-tools'
    Write-CliOut '  install-cli.bat --tool opencode --install-root "%TEMP%\PhaseZero AI" --yes'
    Write-CliOut '  install-cli.bat --tool opencode --uninstall --install-root "%TEMP%\PhaseZero AI" --yes'
    Write-CliOut '  install-cli.bat --tool kimiproxy --install --yes --no-admin'
    Write-CliOut '  install-cli.bat --tool kimiproxy --start --yes --no-admin'
    Write-CliOut '  install-cli.bat --tool ai-proxy-suite --start --yes --no-admin'
    Write-CliOut ''
    Write-CliOut 'Ciclo de vida de configuracao:'
    Write-CliOut '  install-cli.bat --item cursor --export-config "%USERPROFILE%\pz-configs" --yes'
    Write-CliOut '  install-cli.bat --item cursor --import-config "%USERPROFILE%\pz-configs" --yes'
    Write-CliOut '  install-cli.bat --item cursor --import-config https://github.com/voce/seus-configs.git --yes'
    Write-CliOut '  install-cli.bat --item cursor --factory-reset --yes'
    Write-CliOut '  install-cli.bat --batch export --export-config "%USERPROFILE%\pz-configs" --yes   (todos os amarelos)'
    Write-CliOut '  install-cli.bat --export-config ... --include-secrets   (opcional; exporta segredos)'
    Write-CliOut ''
    Write-CliOut 'Web apps (todos de uma vez):'
    Write-CliOut '  install-cli.bat --install-webapps --yes'
    Write-CliOut ''
    Write-CliOut 'Timeout backend:'
    Write-CliOut '  install-cli.bat -Profile PhaseZero --backend-timeout-ms 7200000'
    Write-CliOut '  Env: PHASEZERO_CLI_APPLY_TIMEOUT_MS=7200000'
    Write-CliOut ''
    Write-CliOut 'Reparar configs MCP (npx puro -> cmd /c npx), corrige "Could not attach":'
    Write-CliOut '  install-cli.bat --repair-mcp           (mostra o plano, dry-run)'
    Write-CliOut '  install-cli.bat --repair-mcp --yes     (aplica, com backup .bak)'
    Write-CliOut ''
    Write-CliOut 'Verificar drift (Doctor vs baseline, reporta regressoes):'
    Write-CliOut '  install-cli.bat --drift-check'
}

function ConvertTo-CliCleanReply {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    # BOM/zero-width (U+FEFF, U+200B-U+200D) chegam via stdin redirecionado (ex.: type respostas.txt |
    # install-cli.bat com arquivo salvo como UTF-8 com BOM) e NAO sao removidos por Trim() no
    # .NET Framework; sem isso a opcao "5" vira "<BOM>5" e cai em "Opcao invalida".
    # Chars construidos por code point para nao depender do encoding com que este arquivo e lido.
    foreach ($cp in @(0xFEFF, 0x200B, 0x200C, 0x200D)) {
        $text = $text.Replace([string][char]$cp, '')
    }
    return $text.Trim()
}

function Read-HostOrDefault {
    param([string]$Prompt, [string]$Default = '')
    if ([bool]$script:Options.NonInteractive) { return $Default }
    $reply = ConvertTo-CliCleanReply (Read-Host $Prompt)
    if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
    return $reply
}

function Write-CliLine {
    param([AllowNull()][string]$Text = '')
    Write-Output ([string]$Text)
}

function Get-CliOutputWidth {
    try {
        $width = [int][Console]::WindowWidth
    } catch {
        $width = 100
    }

    if ($width -lt 80) { return 80 }
    if ($width -gt 118) { return 118 }
    return $width
}

function Split-CliTextLine {
    param(
        [AllowNull()][string]$Text,
        [ValidateRange(20, 200)][int]$Width
    )

    $normalized = ([string]$Text -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return @('') }

    $lines = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($word in @($normalized -split ' ')) {
        $remaining = [string]$word
        while ($remaining.Length -gt $Width) {
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                $lines.Add($current) | Out-Null
                $current = ''
            }
            $lines.Add($remaining.Substring(0, $Width)) | Out-Null
            $remaining = $remaining.Substring($Width)
        }

        if ([string]::IsNullOrWhiteSpace($current)) {
            $current = $remaining
        } elseif (($current.Length + 1 + $remaining.Length) -le $Width) {
            $current = "$current $remaining"
        } else {
            $lines.Add($current) | Out-Null
            $current = $remaining
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $lines.Add($current) | Out-Null
    }
    return @($lines.ToArray())
}

function Write-CliProfileRow {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Description,
        [ValidateRange(80, 118)][int]$Width
    )

    $nameWidth = 28
    $prefixWidth = 2 + $nameWidth + 2
    $descriptionWidth = [Math]::Max(30, ($Width - $prefixWidth))
    $wrapped = @(Split-CliTextLine -Text $Description -Width $descriptionWidth)
    Write-CliLine -Text ('  {0,-28}  {1}' -f $Name, $wrapped[0])
    for ($i = 1; $i -lt $wrapped.Count; $i++) {
        Write-CliLine -Text ('  {0,-28}  {1}' -f '', $wrapped[$i])
    }
}

function Get-CliProfileGroupMap {
    $groups = [ordered]@{}
    $groups['Perfis recomendados'] = @('recommended', 'safe-base', 'public-beta', 'base', 'full-workstation', 'full')
    $groups['Steam Deck'] = @(
        'steamdeck-recommended', 'steamdeck-full', 'steamdeck-essentials', 'steamdeck-input',
        'steamdeck-input-advanced', 'steamdeck-power', 'steamdeck-dock', 'steamdeck-storage',
        'steamdeck-connectivity', 'steamdeck-qol', 'steamdeck-capture', 'steamdeck-backup'
    )
    $groups['Categorias opcionais'] = @(
        'containers', 'ai', 'dev-ai', 'support-tools', 'security', 'utilities', 'creator',
        'game-dev', 'gaming', 'automation', 'social', 'workspace', 'legacy'
    )
    return $groups
}

function Write-CliProfileCatalog {
    param([Parameter(Mandatory = $true)][hashtable]$Profiles)

    $width = Get-CliOutputWidth
    $written = @{}
    Write-CliLine -Text ('Nome'.PadRight(30) + 'Descricao')
    Write-CliLine -Text ('-' * $width)

    $groups = Get-CliProfileGroupMap
    foreach ($groupName in $groups.Keys) {
        Write-CliLine
        Write-CliLine -Text $groupName
        foreach ($profileName in @($groups[$groupName])) {
            if (-not $Profiles.Contains($profileName)) { continue }
            $profileDef = $Profiles[$profileName]
            Write-CliProfileRow -Name ([string]$profileDef.Name) -Description ([string]$profileDef.Description) -Width $width
            $written[$profileName] = $true
        }
    }

    $remaining = @($Profiles.Keys | Where-Object { -not $written.ContainsKey([string]$_) } | Sort-Object)
    if ($remaining.Count -gt 0) {
        Write-CliLine
        Write-CliLine -Text 'Outros'
        foreach ($profileName in $remaining) {
            $profileDef = $Profiles[$profileName]
            Write-CliProfileRow -Name ([string]$profileDef.Name) -Description ([string]$profileDef.Description) -Width $width
        }
    }
}

function ConvertTo-CliSearchKey {
    param([AllowNull()][object]$Value)

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }

    try {
        $normalized = @(Normalize-BootstrapNames -Names @($text))
        if ($normalized.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$normalized[0])) {
            return ([string]$normalized[0]).ToLowerInvariant()
        }
    } catch {
    }

    return (($text -replace '[^\p{L}\p{Nd}]+', '-').Trim('-')).ToLowerInvariant()
}

function Get-CliCatalogValue {
    param(
        [AllowNull()]$Entry,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = ''
    )

    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains($Name)) {
        return $Entry[$Name]
    }

    $property = $Entry.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertTo-CliScalarText {
    param([AllowNull()]$Value)

    $items = @($Value)
    if ($items.Count -eq 0) { return '' }
    return [string]$items[0]
}

function Add-CliUniqueValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$List,
        [AllowNull()][object]$Value
    )

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    if (-not $List.Contains($text)) { $List.Add($text) | Out-Null }
}

function New-CliCatalogEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Category = '',
        [string]$Component = '',
        [string]$Source = '',
        [string]$Actions = '',
        [string]$Risk = '',
        [string[]]$Aliases = @(),
        [string[]]$Terms = @()
    )

    $termList = New-Object System.Collections.Generic.List[string]
    Add-CliUniqueValue -List $termList -Value $Id
    Add-CliUniqueValue -List $termList -Value $Title
    Add-CliUniqueValue -List $termList -Value $Component
    Add-CliUniqueValue -List $termList -Value $Category
    Add-CliUniqueValue -List $termList -Value $Source
    foreach ($term in @($Terms)) { Add-CliUniqueValue -List $termList -Value $term }

    $searchKeys = New-Object System.Collections.Generic.List[string]
    foreach ($term in @($termList.ToArray())) {
        $key = ConvertTo-CliSearchKey -Value $term
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $searchKeys.Contains($key)) {
            $searchKeys.Add($key) | Out-Null
        }
    }

    $aliasKeys = New-Object System.Collections.Generic.List[string]
    foreach ($alias in @($Aliases)) {
        $key = ConvertTo-CliSearchKey -Value $alias
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            if (-not $aliasKeys.Contains($key)) { $aliasKeys.Add($key) | Out-Null }
            if (-not $searchKeys.Contains($key)) { $searchKeys.Add($key) | Out-Null }
        }
    }

    return [pscustomobject]@{
        number = $Number
        kind = $Kind
        id = $Id
        title = $Title
        category = $Category
        component = $Component
        source = $Source
        actions = $Actions
        risk = $Risk
        aliasSearchKeys = @($aliasKeys.ToArray())
        terms = @($termList.ToArray())
        searchKeys = @($searchKeys.ToArray())
    }
}

function Get-CliCatalogEntries {
    param([Parameter(Mandatory = $true)][ValidateSet('app','config','config-category','tool')][string]$Kind)

    $entries = New-Object System.Collections.Generic.List[object]
    $number = 1

    if ($Kind -eq 'app') {
        $componentCatalog = Get-BootstrapComponentCatalog
        foreach ($app in @(Get-BootstrapAppCatalog | Sort-Object app, displayName, component)) {
            $source = if ([string]::IsNullOrWhiteSpace([string]$app.wingetId)) { [string]$app.provisioning } else { "winget:$($app.wingetId)" }
            $terms = @([string]$app.app, [string]$app.displayName, [string]$app.component, [string]$app.wingetId)
            $componentDef = if ($componentCatalog.Contains([string]$app.component)) { $componentCatalog[[string]$app.component] } else { $null }
            $componentKind = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $componentDef -Name 'Kind')
            $risk = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $componentDef -Name 'riskLevel')
            if ([string]::IsNullOrWhiteSpace($risk)) { $risk = if ($componentKind -eq 'manual-required') { 'manual' } else { 'safe' } }
            $actions = if ($componentKind -eq 'manual-required') { 'manual,audit' } else { 'install,audit' }
            $entries.Add((New-CliCatalogEntry -Kind 'app' -Number $number -Id ([string]$app.id) -Title ([string]$app.displayName) -Component ([string]$app.component) -Source $source -Actions $actions -Risk $risk -Terms $terms)) | Out-Null
            $number++
        }
        return @($entries.ToArray())
    }

    if ($Kind -eq 'tool') {
        $toolCatalog = Get-BootstrapAiToolCatalog
        foreach ($toolName in @($toolCatalog.Keys | Sort-Object)) {
            $tool = $toolCatalog[$toolName]
            $idValue = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'ToolName' -Default $toolName)
            $id = if ([string]::IsNullOrWhiteSpace($idValue)) { [string]$toolName } else { $idValue }
            $displayName = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'DisplayName' -Default $id)
            $title = if ([string]::IsNullOrWhiteSpace($displayName)) { $id } else { $displayName }
            $support = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'InstallSupport')
            $githubRepo = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'GitHubRepo')
            $docsUrl = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'DocsUrl')
            $packageName = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'PackageName')
            $source = if (-not [string]::IsNullOrWhiteSpace($githubRepo)) { "github:$githubRepo" } elseif (-not [string]::IsNullOrWhiteSpace($support)) { $support } else { $docsUrl }
            $category = if ($support -match 'proxy|ai-proxy-suite') { 'ai-proxy' } else { 'ai-tool' }
            $aliases = @((Get-CliCatalogValue -Entry $tool -Name 'Aliases' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $commandNames = @((Get-CliCatalogValue -Entry $tool -Name 'CommandNames' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $aliasText = (@($aliases) -join ' ')
            $actions = if ($support -match 'manual|workflow') { 'validate,manual' } else { 'install,validate,configure' }
            if ($support -match 'proxy|ai-proxy-suite') { $actions += ',start' }
            $risk = if ($support -match 'manual|workflow') { 'manual' } elseif ($support -match 'proxy|ai-proxy-suite') { 'experimental' } else { 'conservative' }
            $terms = @(
                @($aliases),
                @($commandNames),
                $docsUrl,
                (ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'RepoUrl')),
                $githubRepo,
                $packageName,
                (ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'WingetId')),
                (ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $tool -Name 'Notes'))
            )
            $componentText = if (-not [string]::IsNullOrWhiteSpace($aliasText)) { $aliasText } else { $packageName }
            $entries.Add((New-CliCatalogEntry -Kind 'tool' -Number $number -Id $id -Title $title -Category $category -Component $componentText -Source $source -Actions $actions -Risk $risk -Aliases @($aliases) -Terms $terms)) | Out-Null
            $number++
        }
        return @($entries.ToArray())
    }

    $catalog = Get-BootstrapAppTuningCatalog
    $categoryLookup = @{}
    foreach ($category in @($catalog.categories)) {
        $categoryLookup[[string]$category.id] = [string]$category.displayName
    }

    if ($Kind -eq 'config-category') {
        foreach ($category in @($catalog.categories | Sort-Object id)) {
            $id = [string]$category.id
            $title = if ([string]::IsNullOrWhiteSpace([string]$category.displayName)) { $id } else { [string]$category.displayName }
            $entries.Add((New-CliCatalogEntry -Kind 'category' -Number $number -Id $id -Title $title -Category $id -Terms @([string]$category.description))) | Out-Null
            $number++
        }
        return @($entries.ToArray())
    }

    $configItems = @(
        $catalog.items |
            Where-Object { [string](Get-CliCatalogValue -Entry $_ -Name 'id') -notmatch '^app-' } |
            Sort-Object `
                @{ Expression = { [string](Get-CliCatalogValue -Entry $_ -Name 'category') } }, `
                @{ Expression = { [string](Get-CliCatalogValue -Entry $_ -Name 'displayName') } }, `
                @{ Expression = { [string](Get-CliCatalogValue -Entry $_ -Name 'id') } }
    )
    foreach ($item in $configItems) {
        $id = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $item -Name 'id')
        $category = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $item -Name 'category')
        $displayName = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $item -Name 'displayName')
        $title = if ([string]::IsNullOrWhiteSpace($displayName)) { $id } else { $displayName }
        $categoryTitle = if ($categoryLookup.ContainsKey($category) -and -not [string]::IsNullOrWhiteSpace([string]$categoryLookup[$category])) { [string]$categoryLookup[$category] } else { $category }
        $targetApps = @((Get-CliCatalogValue -Entry $item -Name 'targetApps' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $actions = @((Get-CliCatalogValue -Entry $item -Name 'actions' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $profiles = @((Get-CliCatalogValue -Entry $item -Name 'profiles' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $installComponents = @((Get-CliCatalogValue -Entry $item -Name 'installComponents' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $aliases = @((Get-CliCatalogValue -Entry $item -Name 'aliases' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $badges = @((Get-CliCatalogValue -Entry $item -Name 'badges' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $risk = Get-BootstrapAppTuningRiskTier -Item $item
        $description = ConvertTo-CliScalarText (Get-CliCatalogValue -Entry $item -Name 'description')
        $terms = @(
            $description,
            @($targetApps) -join ' ',
            @($actions) -join ' ',
            @($profiles) -join ' ',
            @($installComponents) -join ' ',
            @($aliases) -join ' ',
            @($badges) -join ' ',
            $categoryTitle
        )
        $entries.Add((New-CliCatalogEntry -Kind 'config' -Number $number -Id $id -Title $title -Category $category -Component ((@($installComponents) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ',') -Source $categoryTitle -Actions ((@($actions) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ',') -Risk $risk -Aliases @($aliases) -Terms $terms)) | Out-Null
        $number++
    }
    return @($entries.ToArray())
}

function Get-CliTermPreview {
    param([string[]]$Terms)
    $kept = @()
    foreach ($term in @($Terms)) {
        if ([string]::IsNullOrWhiteSpace([string]$term)) { continue }
        if (@($kept) -contains [string]$term) { continue }
        $kept += @([string]$term)
        if ($kept.Count -ge 4) { break }
    }
    return ($kept -join ', ')
}

function Resolve-CliEntryStatus {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('app','config','tool')][string]$Kind,
        [Parameter(Mandatory = $true)]$Entry,
        [hashtable]$Cache
    )

    $probePaths = @()
    $commandNames = @()
    if ($Kind -eq 'app') {
        $componentCatalog = Get-BootstrapComponentCatalog
        $component = [string]$Entry.component
        if (-not [string]::IsNullOrWhiteSpace($component) -and $componentCatalog.Contains($component)) {
            $def = $componentCatalog[$component]
            if ($def.PSObject.Properties.Name -contains 'ProbePaths') { $probePaths = @($def.ProbePaths) }
        }
    } elseif ($Kind -eq 'tool') {
        $toolCatalog = Get-BootstrapAiToolCatalog
        if ($toolCatalog.Contains([string]$Entry.id)) {
            $commandNames = @((Get-CliCatalogValue -Entry $toolCatalog[[string]$Entry.id] -Name 'CommandNames' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }
    }

    $status = Get-BootstrapItemStatus -Kind $Kind -Id ([string]$Entry.id) -ProbePaths $probePaths -CommandNames $commandNames -Cache $Cache
    return [pscustomobject]@{ status = $status; color = [System.ConsoleColor](Get-BootstrapItemStatusColor -Status $status) }
}

function Write-CliStatusLegend {
    Write-CliOut 'Legenda de status:' Cyan
    foreach ($info in (Get-BootstrapItemStatusInfo)) {
        Write-CliOut ('  * {0}' -f [string]$info.label) ([System.ConsoleColor][string]$info.color)
    }
    Write-CliOut ''
}

function Write-CliCatalogEntries {
    param([Parameter(Mandatory = $true)][ValidateSet('app','config','tool')][string]$Kind)

    $entries = @(Get-CliCatalogEntries -Kind $Kind)
    $label = switch ($Kind) {
        'app' { 'app' }
        'config' { 'config' }
        default { 'tool' }
    }
    $statusCache = Read-BootstrapItemStatusCache
    Write-CliStatusLegend
    $currentCategory = ''
    foreach ($entry in $entries) {
        if ($Kind -eq 'config' -and [string]$entry.category -ne $currentCategory) {
            $currentCategory = [string]$entry.category
            Write-CliOut ''
            Write-CliOut ("[{0}] {1}" -f $currentCategory, [string]$entry.source) Cyan
        }
        $termPreview = Get-CliTermPreview -Terms @($entry.terms)
        $statusInfo = Resolve-CliEntryStatus -Kind $Kind -Entry $entry -Cache $statusCache
        if ($Kind -eq 'app') {
            Write-CliOut ('{0,3}. [app] {1} | {2} | component: {3} | termos: {4} | source: {5}' -f [int]$entry.number, [string]$entry.id, [string]$entry.title, [string]$entry.component, $termPreview, [string]$entry.source) $statusInfo.color
        } elseif ($Kind -eq 'config') {
            Write-CliOut ('{0,3}. [config] {1} | {2} | categoria: {3} | termos: {4} | acoes: {5} | risco: {6}' -f [int]$entry.number, [string]$entry.id, [string]$entry.title, [string]$entry.category, $termPreview, [string]$entry.actions, [string]$entry.risk) $statusInfo.color
        } else {
            Write-CliOut ('{0,3}. [tool] {1} | {2} | categoria: {3} | termos: {4} | source: {5}' -f [int]$entry.number, [string]$entry.id, [string]$entry.title, [string]$entry.category, $termPreview, [string]$entry.source) $statusInfo.color
        }
    }
    Write-CliOut ''
    if ($Kind -eq 'tool') {
        Write-CliOut 'Dica: use numero, ID ou termo. Instalar: .\install-cli.bat --tool <termo> --install --yes. Iniciar: .\install-cli.bat --tool <termo> --start --yes --no-admin' Yellow
    } else {
        Write-CliOut ("Dica: use numero, ID ou qualquer termo listado. Ex: .\install-cli.bat --{0} <termo> --dry-run --yes" -f $(if ($Kind -eq 'app') { 'app' } else { 'config' })) Yellow
    }
}

function Get-CliUnifiedCatalogEntries {
    $unified = New-Object System.Collections.Generic.List[object]
    $number = 1
    foreach ($kind in @('app','config','tool')) {
        foreach ($entry in @(Get-CliCatalogEntries -Kind $kind)) {
            $unified.Add([pscustomobject]@{
                number = $number
                kind = $kind
                entry = $entry
            }) | Out-Null
            $number++
        }
    }
    return @($unified.ToArray())
}

function Write-CliUnifiedCatalogEntries {
    $statusCache = Read-BootstrapItemStatusCache
    Write-CliStatusLegend
    $currentGroup = ''
    foreach ($item in @(Get-CliUnifiedCatalogEntries)) {
        $entry = $item.entry
        $group = switch ([string]$item.kind) {
            'app' { 'apps' }
            'config' { [string]$entry.category }
            default { [string]$entry.category }
        }
        if ($group -ne $currentGroup) {
            $currentGroup = $group
            Write-CliOut ''
            Write-CliOut ("[{0}]" -f $currentGroup) Cyan
        }
        $statusInfo = Resolve-CliEntryStatus -Kind ([string]$item.kind) -Entry $entry -Cache $statusCache
        Write-CliOut ('{0,3}. [{1}] {2} | {3} | acoes: {4} | risco: {5}' -f
            [int]$item.number,
            [string]$item.kind,
            [string]$entry.id,
            [string]$entry.title,
            [string]$entry.actions,
            [string]$entry.risk) $statusInfo.color
    }
    Write-CliOut ''
    Write-CliOut 'Dica: use numero global, ID, alias ou nome. Ex: .\install-cli.bat --item <termo> --dry-run --yes' Yellow
}

function Find-CliCatalogMatches {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('app','config','config-category','tool')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $entries = @(Get-CliCatalogEntries -Kind $Kind)
    $clean = (ConvertTo-CliCleanReply $Token)
    if ([string]::IsNullOrWhiteSpace($clean)) { return @() }

    $number = 0
    if ([int]::TryParse($clean, [ref]$number)) {
        return @($entries | Where-Object { [int]$_.number -eq $number })
    }

    $key = ConvertTo-CliSearchKey -Value $clean
    if ([string]::IsNullOrWhiteSpace($key)) { return @() }

    $exact = @($entries | Where-Object { @($_.searchKeys) -contains $key })
    if ($exact.Count -gt 0) { return @($exact) }

    return @($entries | Where-Object {
        $matched = $false
        foreach ($searchKey in @($_.searchKeys)) {
            if ([string]$searchKey -like "*$key*") { $matched = $true; break }
        }
        $matched
    })
}

function Resolve-CliCatalogToken {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('app','config','config-category','tool')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $matches = @(Find-CliCatalogMatches -Kind $Kind -Token $Token)
    if ($matches.Count -eq 1) { return $matches[0] }
    $clean = ConvertTo-CliCleanReply $Token
    $key = ConvertTo-CliSearchKey -Value $clean
    if (-not [string]::IsNullOrWhiteSpace($key)) {
        $aliasMatches = @($matches | Where-Object { @($_.aliasSearchKeys) -contains $key })
        if ($aliasMatches.Count -eq 1) { return $aliasMatches[0] }
    }
    if ($Kind -eq 'tool' -and $matches.Count -gt 1) {
        $withoutSuite = @($matches | Where-Object { [string]$_.id -ne 'ai-proxy-suite' })
        if ($withoutSuite.Count -eq 1) { return $withoutSuite[0] }
    }

    $label = switch ($Kind) {
        'app' { 'app' }
        'config' { 'configuracao' }
        'tool' { 'AI tool' }
        default { 'categoria' }
    }

    if ($matches.Count -eq 0) {
        throw "Nenhum $label encontrado para '$Token'. Use --list-apps, --list-configs ou --list-tools para ver numeros, IDs e termos."
    }

    $sample = (@($matches | Select-Object -First 8 | ForEach-Object { "{0}. {1} ({2})" -f [int]$_.number, [string]$_.id, [string]$_.title }) -join '; ')
    throw "Termo ambiguo para $label '$Token'. Refine a busca ou use o numero/ID. Opcoes: $sample"
}

function Resolve-CliOptionTerms {
    param([Parameter(Mandatory = $true)]$Options)

    $resolvedApps = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Options.App)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $entry = Resolve-CliCatalogToken -Kind 'app' -Token ([string]$value)
        if (-not $resolvedApps.Contains([string]$entry.id)) { $resolvedApps.Add([string]$entry.id) | Out-Null }
    }
    $Options.App = @($resolvedApps.ToArray())

    $resolvedConfigs = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Options.Config)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $entry = Resolve-CliCatalogToken -Kind 'config' -Token ([string]$value)
        if (-not $resolvedConfigs.Contains([string]$entry.id)) { $resolvedConfigs.Add([string]$entry.id) | Out-Null }
    }
    $Options.Config = @($resolvedConfigs.ToArray())

    $resolvedCategories = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Options.ConfigCategory)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $entry = Resolve-CliCatalogToken -Kind 'config-category' -Token ([string]$value)
        if (-not $resolvedCategories.Contains([string]$entry.id)) { $resolvedCategories.Add([string]$entry.id) | Out-Null }
    }
    $Options.ConfigCategory = @($resolvedCategories.ToArray())
}

function Resolve-CliToolTerms {
    param(
        [Parameter(Mandatory = $true)]$Options,
        [Parameter(Mandatory = $true)][hashtable]$Catalog
    )

    $resolvedTools = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Options.Tool)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $entry = Resolve-CliCatalogToken -Kind 'tool' -Token ([string]$value)
        if (-not $Catalog.Contains([string]$entry.id)) {
            throw "AI tool desconhecida: $value"
        }
        if (-not $resolvedTools.Contains([string]$entry.id)) { $resolvedTools.Add([string]$entry.id) | Out-Null }
    }
    $Options.Tool = @($resolvedTools.ToArray())
}

function Resolve-CliUnifiedItemTerms {
    param([Parameter(Mandatory = $true)]$Options)

    if (@($Options.Item).Count -eq 0) { return }

    foreach ($value in @($Options.Item)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $clean = ConvertTo-CliCleanReply ([string]$value)
        $searchKey = ConvertTo-CliSearchKey -Value $clean
        $matches = New-Object System.Collections.Generic.List[object]
        $globalNumber = 0
        if ([int]::TryParse($clean, [ref]$globalNumber)) {
            foreach ($item in @(Get-CliUnifiedCatalogEntries | Where-Object { [int]$_.number -eq $globalNumber })) {
                $matches.Add([pscustomobject]@{ kind = [string]$item.kind; entry = $item.entry }) | Out-Null
            }
        } else {
            foreach ($kind in @('app','config','tool')) {
                foreach ($entry in @(Find-CliCatalogMatches -Kind $kind -Token $clean)) {
                    $matches.Add([pscustomobject]@{ kind = $kind; entry = $entry }) | Out-Null
                }
            }
        }

        if ($matches.Count -eq 0) {
            throw "Nenhum item encontrado para '$value'. Use --list-apps, --list-configs ou --list-tools."
        }

        $aliasExact = @($matches.ToArray() | Where-Object { @($_.entry.aliasSearchKeys) -contains $searchKey })
        if ($aliasExact.Count -eq 1) {
            $candidates = @($aliasExact)
        } elseif ($aliasExact.Count -gt 1) {
            $candidates = @($aliasExact)
        } else {
        $exact = @($matches.ToArray() | Where-Object {
            ([string]$_.entry.id -eq $clean) -or (@($_.entry.searchKeys) -contains $searchKey)
        })
        $candidates = @(if ($exact.Count -gt 0) { $exact } else { $matches.ToArray() })
        }
        if ($candidates.Count -ne 1) {
            $sample = (@($candidates | Select-Object -First 8 | ForEach-Object { "{0}:{1}. {2}" -f [string]$_.kind, [int]$_.entry.number, [string]$_.entry.id }) -join '; ')
            throw "Termo ambiguo para item '$value'. Use numero/ID com --app, --config ou --tool. Opcoes: $sample"
        }

        $selected = $candidates[0]
        switch ([string]$selected.kind) {
            'app' {
                if (@($Options.App) -notcontains [string]$selected.entry.id) { $Options.App += @([string]$selected.entry.id) }
            }
            'config' {
                if (@($Options.Config) -notcontains [string]$selected.entry.id) { $Options.Config += @([string]$selected.entry.id) }
            }
            'tool' {
                if (@($Options.Tool) -notcontains [string]$selected.entry.id) { $Options.Tool += @([string]$selected.entry.id) }
            }
        }
    }

    $Options.Item = @()
}

function Read-CliCatalogSelection {
    param([Parameter(Mandatory = $true)][ValidateSet('app','config','tool')][string]$Kind)

    $title = switch ($Kind) {
        'app' { 'Apps individuais disponiveis' }
        'config' { 'Configuracoes individuais disponiveis' }
        default { 'AI tools e proxies disponiveis' }
    }
    while ($true) {
        Write-CliOut ''
        Write-CliOut $title Green
        Write-CliOut ''
        Write-CliCatalogEntries -Kind $Kind
        Write-CliOut 'Digite numero, ID ou termo (0 cancela)' Cyan
        $reply = ConvertTo-CliCleanReply (Read-Host)
        if ([string]::IsNullOrWhiteSpace($reply) -or $reply -eq '0') { return $null }
        $matches = @(Find-CliCatalogMatches -Kind $Kind -Token $reply)
        if ($matches.Count -eq 1) { return $matches[0] }
        if ($matches.Count -eq 0) {
            Write-CliOut ("[AVISO] Nenhum item encontrado para: {0}" -f $reply) Yellow
            continue
        }
        Write-CliOut '[AVISO] Termo ambiguo. Use numero ou ID de uma das opcoes:' Yellow
        foreach ($match in @($matches | Select-Object -First 12)) {
            Write-CliOut ('  {0}. {1} | {2}' -f [int]$match.number, [string]$match.id, [string]$match.title) Yellow
        }
    }
}

function Resolve-CliLogPath {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) { return [System.IO.Path]::GetFullPath($RequestedPath) }
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    return (Join-Path $root ("phasezero-install-cli-ai-tools-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)))
}

function Get-CliProfileMenuEntries {
    # Lista numerada de TODOS os perfis do catalogo, agrupada (mesma ordem do catalogo visual),
    # para que o que aparece na lista seja exatamente o que o usuario pode escolher e instalar.
    param([Parameter(Mandatory = $true)][hashtable]$Profiles)

    $entries = New-Object System.Collections.Generic.List[object]
    $written = @{}
    $number = 0
    $groups = Get-CliProfileGroupMap
    foreach ($groupName in $groups.Keys) {
        foreach ($profileName in @($groups[$groupName])) {
            if (-not $Profiles.Contains($profileName) -or $written.ContainsKey([string]$profileName)) { continue }
            $number++
            $def = $Profiles[$profileName]
            $entries.Add([pscustomobject]@{ number = $number; group = [string]$groupName; key = [string]$profileName; name = [string]$def.Name; description = [string]$def.Description }) | Out-Null
            $written[[string]$profileName] = $true
        }
    }
    foreach ($profileName in @($Profiles.Keys | Where-Object { -not $written.ContainsKey([string]$_) } | Sort-Object)) {
        $number++
        $def = $Profiles[$profileName]
        $entries.Add([pscustomobject]@{ number = $number; group = 'Outros'; key = [string]$profileName; name = [string]$def.Name; description = [string]$def.Description }) | Out-Null
        $written[[string]$profileName] = $true
    }
    return @($entries.ToArray())
}

function Read-CliProfileSelection {
    # Mostra a lista numerada e aceita numero, nome ou alias; retorna o nome do perfil ('' = voltar).
    param([Parameter(Mandatory = $true)][hashtable]$Profiles)

    $entries = Get-CliProfileMenuEntries -Profiles $Profiles
    $width = Get-CliOutputWidth
    # IMPORTANTE: render via Write-CliOut ([Console]::WriteLine -> host). Nao usar Write-CliProfileRow
    # aqui: ele escreve no pipeline e poluiria o valor de retorno desta funcao (capturado pelo caller).
    $nameWidth = 30
    $descriptionWidth = [Math]::Max(30, ($width - ($nameWidth + 4)))
    while ($true) {
        Write-CliOut ''
        Write-CliOut 'Instalacao guiada por perfil' Green
        $currentGroup = ''
        foreach ($entry in $entries) {
            if ([string]$entry.group -ne $currentGroup) {
                $currentGroup = [string]$entry.group
                Write-CliOut ''
                Write-CliOut $currentGroup Cyan
            }
            $label = '{0,3}. {1}' -f [int]$entry.number, [string]$entry.name
            $wrapped = @(Split-CliTextLine -Text ([string]$entry.description) -Width $descriptionWidth)
            Write-CliOut ('  {0}  {1}' -f $label.PadRight($nameWidth), $wrapped[0])
            for ($i = 1; $i -lt $wrapped.Count; $i++) {
                Write-CliOut ('  {0}  {1}' -f ''.PadRight($nameWidth), $wrapped[$i])
            }
        }
        Write-CliOut ''
        $reply = ConvertTo-CliCleanReply (Read-Host 'Numero ou nome do perfil (0=voltar)')
        if ([string]::IsNullOrWhiteSpace($reply) -or $reply -eq '0') { return '' }
        $number = 0
        if ([int]::TryParse($reply, [ref]$number)) {
            $match = $entries | Where-Object { [int]$_.number -eq $number } | Select-Object -First 1
            if ($null -ne $match) { return [string]$match.key }
        } else {
            $match = $entries | Where-Object { [string]$_.key -eq $reply -or [string]$_.name -eq $reply } | Select-Object -First 1
            if ($null -ne $match) { return [string]$match.key }
            if ($Profiles.Contains($reply)) { return $reply }
        }
        Write-CliOut ("[AVISO] Perfil nao encontrado: {0}" -f $reply) Yellow
    }
}

function Invoke-CliMenuProfileFlow {
    # Fluxo coeso de perfil: escolher -> pre-visualizar (dry-run) -> confirmar -> instalar.
    # Retorna o exit code do backend (0 tambem quando o usuario volta/cancela). Nao encerra o processo.
    param(
        [Parameter(Mandatory = $true)]$Options,
        [Parameter(Mandatory = $true)][hashtable]$Profiles
    )

    $profileChoice = Read-CliProfileSelection -Profiles $Profiles
    if ([string]::IsNullOrWhiteSpace($profileChoice)) { return 0 }

    Write-CliOut ''
    Write-CliOut ("[1/3] Perfil selecionado: {0}" -f $profileChoice) Green
    Write-CliOut ''
    Write-CliOut ("[2/3] Pre-visualizando (dry-run): {0}" -f $profileChoice) Green
    $dryArgs = Add-CliBackendArtifactArg -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ToolsPs1,
        '-Profile', $profileChoice,
        '-DryRun', '-NonInteractive', '-SkipManualRequirements'
    )
    $dryExit = [int](Invoke-CliBackendProcess -ArgumentList $dryArgs -OperationName 'dry-run').ExitCode
    if ($dryExit -ne 0) {
        Write-CliOut ("[ERRO] Dry-run falhou (codigo {0})." -f $dryExit) Red
        Write-CliOut ("Result: {0}" -f [string]$Options.ResultPath) Yellow
        Write-CliOut ("Log:    {0}" -f [string]$Options.LogPath) Yellow
        return $dryExit
    }

    Write-CliOut ''
    $confirm = ConvertTo-CliCleanReply (Read-Host ("Instalar o perfil '{0}' agora? (S/N)" -f $profileChoice))
    if ($confirm -notmatch '^[Ss]$') {
        Write-CliOut '[AVISO] Instalacao cancelada pelo usuario.' Yellow
        return 0
    }

    Write-CliOut ''
    Write-CliOut ("[3/3] Instalando perfil: {0}" -f $profileChoice) Green
    Write-CliOut 'Isso pode levar varios minutos dependendo das dependencias...' Yellow
    $installArgs = Add-CliBackendArtifactArg -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ToolsPs1,
        '-Profile', $profileChoice,
        '-NonInteractive', '-SkipManualRequirements'
    )
    $installExit = [int](Invoke-CliBackendProcess -ArgumentList $installArgs -OperationName 'apply').ExitCode
    Write-CliOut ''
    if ($installExit -eq 0) {
        Write-Header 'SUCESSO: perfil instalado'
        Write-CliOut ("Result: {0}" -f [string]$Options.ResultPath) Green
        Write-CliOut ("Log:    {0}" -f [string]$Options.LogPath) Green
    } else {
        Write-CliOut ("[ERRO] Instalacao do perfil falhou (codigo {0})." -f $installExit) Red
        Write-CliOut ("Result: {0}" -f [string]$Options.ResultPath) Yellow
        Write-CliOut ("Log:    {0}" -f [string]$Options.LogPath) Yellow
    }
    return $installExit
}

function Show-CliMainMenu {
    Write-CliOut ''
    Write-CliOut 'PhaseZero Bootstrap - menu rapido' Cyan
    Write-CliOut ''
    Write-CliOut 'Diagnostico (seguro, sem alteracoes)' Green
    Write-CliOut '  1) Doctor (diagnostico, dry-run sem alteracoes)' Cyan
    Write-CliOut '  2) Exportar SupportBundle (dry-run, sem alteracoes)' Cyan
    Write-CliOut ''
    Write-CliOut 'Instalar (sempre pre-visualiza com dry-run e pede confirmacao)' Green
    Write-CliOut '  3) Instalacao guiada por perfil (listar, escolher e instalar)' Cyan
    Write-CliOut '  4) App individual (buscar, validar, instalar)' Cyan
    Write-CliOut '  5) Configuracao individual (buscar, validar, aplicar)' Cyan
    Write-CliOut '  6) AI tool/proxy (buscar, instalar, iniciar)' Cyan
    Write-CliOut ''
    Write-CliOut '  0) Sair' Cyan
    Write-CliOut ''
    $reply = Read-Host 'Selecione [1-6, 0=sair]'
    return (ConvertTo-CliCleanReply $reply)
}

function Invoke-CliMenuBackendIntent {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Doctor','SupportBundle','RepairPlan')][string]$Intent
    )
    Write-CliOut ''
    Write-CliOut ("[atalho] Executando -{0} (dry-run, sem alteracoes)..." -f $Intent) Green
    Write-CliOut ''
    $argsList = Add-CliBackendArtifactArg -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass',
        '-File', $ToolsPs1,
        ("-{0}" -f $Intent),
        '-DryRun','-NonInteractive'
    )
    $process = Invoke-CliBackendProcess -ArgumentList $argsList -OperationName 'dry-run'
    $exit = [int]$process.ExitCode
    if ($exit -ne 0) {
        Write-CliOut ''
        Write-CliOut ("[ERRO] Atalho {0} falhou (codigo {1})." -f $Intent, $exit) Red
        Write-CliOut ("Log:    {0}" -f [string]$script:Options.LogPath) Yellow
        Write-CliOut ("Result: {0}" -f [string]$script:Options.ResultPath) Yellow
        Write-CliOut ("Retome com: .\bootstrap-tools.ps1 -{0} -DryRun -NonInteractive" -f $Intent) Yellow
    }
    return $exit
}

function Write-CliLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    if ([string]::IsNullOrWhiteSpace([string]$script:CliLogPath)) { return }
    $parent = Split-Path -Path $script:CliLogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    $row = [ordered]@{
        time    = (Get-Date).ToString('o')
        level   = $Level
        message = $Message
    }
    Add-Content -LiteralPath $script:CliLogPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
}

function Complete-CliResultEnvelope {
    param([Parameter(Mandatory = $true)]$Payload)

    $result = [ordered]@{}
    if ($Payload -is [System.Collections.IDictionary]) {
        foreach ($key in $Payload.Keys) { $result[[string]$key] = $Payload[$key] }
    } else {
        foreach ($prop in @($Payload.PSObject.Properties)) { $result[[string]$prop.Name] = $prop.Value }
    }

    if (-not $result.Contains('generatedAt')) { $result['generatedAt'] = (Get-Date).ToString('o') }
    if (-not $result.Contains('logPath')) { $result['logPath'] = [string]$script:Options.LogPath }
    if (-not $result.Contains('resultPath')) { $result['resultPath'] = [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath) }
    $result['logPath'] = [string](@($result['logPath'])[0])
    $result['resultPath'] = [string](@($result['resultPath'])[0])
    if (-not $result.Contains('exitCode')) {
        $status = if ($result.Contains('status')) { [string]$result['status'] } else { 'success' }
        $result['exitCode'] = if ($status -eq 'blocked') { 2 } elseif ($status -eq 'error') { 1 } else { 0 }
    }
    if (-not $result.Contains('artifactPaths')) {
        $result['artifactPaths'] = [ordered]@{
            logPath = [System.IO.Path]::GetFullPath([string]$script:Options.LogPath)
            resultPath = [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath)
        }
    }
    if (-not $result.Contains('diagnostics')) {
        $message = ''
        if ($result.Contains('error')) { $message = [string]$result['error'] }
        if ([string]::IsNullOrWhiteSpace($message) -and $result.Contains('message')) { $message = [string]$result['message'] }
        $statusText = if ($result.Contains('status')) { [string]$result['status'] } else { 'success' }
        $diagnosticSeverity = switch ($statusText) {
            'blocked' { 'blocked'; break }
            'error' { 'error'; break }
            'warning' { 'warning'; break }
            default { '' }
        }
        if ([string]::IsNullOrWhiteSpace($message) -or [string]::IsNullOrWhiteSpace($diagnosticSeverity)) {
            $result['diagnostics'] = @()
        } else {
            $result['diagnostics'] = @([ordered]@{
                severity = $diagnosticSeverity
                message = $message
                howToFix = $(if ($result.Contains('howToFix')) { [string]$result['howToFix'] } else { '' })
            })
        }
    }
    if (-not $result.Contains('scope')) {
        $result['scope'] = [ordered]@{
            profile = [string]$script:Options.Profile
            tools = @($script:Options.Tool)
            allAiTools = [bool]$script:Options.AllAiTools
        }
    }
    if (-not $result.Contains('rollback')) {
        $result['rollback'] = [ordered]@{
            available = $false
            changesPath = ''
            summary = $null
        }
    }
    return $result
}

function Write-CliJsonResult {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [string]$ResultPath
    )
    $Payload = Complete-CliResultEnvelope -Payload $Payload
    $json = $Payload | ConvertTo-Json -Depth 12
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $full = [System.IO.Path]::GetFullPath($ResultPath)
        $parent = Split-Path -Path $full -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllText($full, $json, [System.Text.UTF8Encoding]::new($false))
    }
    Write-Host $json
}

function Add-CliBackendArtifactArg {
    param([string[]]$ArgumentList)

    $argsOut = @($ArgumentList)
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.LogPath)) {
        $argsOut += @('-LogPath', [System.IO.Path]::GetFullPath([string]$script:Options.LogPath))
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath)) {
        $argsOut += @('-ResultPath', [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath))
    }
    return $argsOut
}

function Join-CliOptionValues {
    param([object[]]$Values)
    return (@($Values) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }) -join ','
}

function Test-CliHasBootstrapSelection {
    param([Parameter(Mandatory = $true)]$Options)
    return (
        @($Options.App).Count -gt 0 -or
        @($Options.Component).Count -gt 0 -or
        @($Options.Config).Count -gt 0 -or
        @($Options.ConfigCategory).Count -gt 0 -or
        @($Options.ExcludeConfig).Count -gt 0
    )
}

function New-CliIsolatedBackendArgs {
    param(
        [Parameter(Mandatory = $true)]$Options,
        [bool]$DryRun
    )

    $backendArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ToolsPs1,
        '-NonInteractive', '-SkipManualRequirements',
        '-HostHealth', 'off'
    )

    if ($DryRun) { $backendArgs += @('-DryRun') }

    $apps = Join-CliOptionValues -Values $Options.App
    if (-not [string]::IsNullOrWhiteSpace($apps)) { $backendArgs += @('-App', $apps) }

    $components = Join-CliOptionValues -Values $Options.Component
    if (-not [string]::IsNullOrWhiteSpace($components)) { $backendArgs += @('-Component', $components) }

    $configs = Join-CliOptionValues -Values $Options.Config
    $configCategories = Join-CliOptionValues -Values $Options.ConfigCategory
    $excludedConfigs = Join-CliOptionValues -Values $Options.ExcludeConfig
    if (-not [string]::IsNullOrWhiteSpace($configs) -or -not [string]::IsNullOrWhiteSpace($configCategories)) {
        $backendArgs += @('-AppTuning', 'custom')
    }
    if (-not [string]::IsNullOrWhiteSpace($configs)) { $backendArgs += @('-AppTuningItem', $configs) }
    if (-not [string]::IsNullOrWhiteSpace($configCategories)) { $backendArgs += @('-AppTuningCategory', $configCategories) }
    if (-not [string]::IsNullOrWhiteSpace($excludedConfigs)) { $backendArgs += @('-ExcludeAppTuningItem', $excludedConfigs) }

    return (Add-CliBackendArtifactArg -ArgumentList $backendArgs)
}

function Add-CliCommandOptionValues {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Parts,
        [Parameter(Mandatory = $true)][string]$OptionName,
        [AllowNull()]$Values
    )

    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $Parts.Add($OptionName) | Out-Null
        $Parts.Add((Format-CliCommandToken -Value ([string]$value))) | Out-Null
    }
}

function Format-CliApplyCommand {
    param([Parameter(Mandatory = $true)]$Options)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('.\install-cli.bat') | Out-Null
    Add-CliCommandOptionValues -Parts $parts -OptionName '--app' -Values $Options.App
    Add-CliCommandOptionValues -Parts $parts -OptionName '--component' -Values $Options.Component
    Add-CliCommandOptionValues -Parts $parts -OptionName '--config' -Values $Options.Config
    Add-CliCommandOptionValues -Parts $parts -OptionName '--config-category' -Values $Options.ConfigCategory
    Add-CliCommandOptionValues -Parts $parts -OptionName '--exclude-config' -Values $Options.ExcludeConfig
    $parts.Add('--yes') | Out-Null
    return ($parts.ToArray() -join ' ')
}

function Format-CliCommandToken {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\s"]') { return ('"{0}"' -f ($Value -replace '"', '\"')) }
    return $Value
}

function ConvertTo-CliCommandLineArgument {
    param([AllowNull()][string]$Token)

    if ($null -eq $Token) { return '""' }
    $text = [string]$Token
    if ($text.Length -eq 0) { return '""' }
    if ($text -notmatch '[\s"`&\(\)\^]') { return $text }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($ch -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($ch -eq [char]'"') {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
            [void]$builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-CliArgumentString {
    param([string[]]$Tokens)
    return [string]::Join(' ', @($Tokens | ForEach-Object { ConvertTo-CliCommandLineArgument -Token ([string]$_) }))
}

function Get-CliBackendTimeoutMs {
    param(
        [string]$OperationName = '',
        [int]$RequestedTimeoutMs = 0
    )

    if ($RequestedTimeoutMs -gt 0) { return $RequestedTimeoutMs }

    try {
        if ($script:Options -and ($script:Options.Contains('BackendTimeoutMs')) -and [int]$script:Options.BackendTimeoutMs -gt 0) {
            return [int]$script:Options.BackendTimeoutMs
        }
    } catch { }

    $envNames = if ([string]$OperationName -eq 'apply') {
        @('PHASEZERO_CLI_APPLY_TIMEOUT_MS', 'PHASEZERO_CLI_BACKEND_TIMEOUT_MS')
    } elseif ([string]$OperationName -eq 'dry-run') {
        @('PHASEZERO_CLI_DRYRUN_TIMEOUT_MS', 'PHASEZERO_CLI_BACKEND_TIMEOUT_MS')
    } else {
        @('PHASEZERO_CLI_BACKEND_TIMEOUT_MS')
    }

    foreach ($name in $envNames) {
        $raw = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = [Environment]::GetEnvironmentVariable($name, 'User') }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        try { return (ConvertTo-CliTimeoutMs -Value $raw -OptionName $name) }
        catch { Write-CliOut ("[AVISO] Ignorando {0}: {1}" -f $name, $_.Exception.Message) Yellow }
    }

    if ([string]$OperationName -eq 'apply') { return 7200000 }
    if ([string]$OperationName -eq 'dry-run') { return 1800000 }
    return 3600000
}

function Invoke-CliBackendProcess {
    # Lanca o backend (powershell.exe) com timeout e captura de stdout/stderr em arquivos ao lado do
    # result.json. Substitui o `Start-Process -Wait` cru (sem timeout, sem captura) das rotas CLI.
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [int]$TimeoutMs = 0
    )

    $TimeoutMs = Get-CliBackendTimeoutMs -OperationName $OperationName -RequestedTimeoutMs $TimeoutMs
    $stdoutPath = [System.IO.Path]::ChangeExtension([string]$script:Options.ResultPath, ".$OperationName.stdout.log")
    $stderrPath = [System.IO.Path]::ChangeExtension([string]$script:Options.ResultPath, ".$OperationName.stderr.log")
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = ConvertTo-CliArgumentString -Tokens $ArgumentList
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch { }
            $message = ("{0} excedeu timeout de {1}ms." -f $OperationName, $TimeoutMs)
            Write-CliLegacyFailureResult -Message $message -ExitCode 124 -Mode $OperationName -HowToFix 'Revise stdout/stderr/log e rode novamente com escopo menor, --backend-timeout-ms maior, PHASEZERO_CLI_APPLY_TIMEOUT_MS, ou Doctor.'
            return [pscustomobject]@{ ExitCode = 124; TimedOut = $true; StdoutPath = $stdoutPath; StderrPath = $stderrPath }
        }
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        [System.IO.File]::WriteAllText($stdoutPath, $stdout, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($stderrPath, $stderr, [System.Text.UTF8Encoding]::new($false))
        # Ecoa a saida capturada ao final (nao ao vivo) para preservar visibilidade do backend.
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.TrimEnd() }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Host $stderr.TrimEnd() -ForegroundColor Yellow }
        return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; TimedOut = $false; StdoutPath = $stdoutPath; StderrPath = $stderrPath }
    } finally {
        try { $process.Dispose() } catch { }
    }
}

function Update-CliResultFileMode {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [int]$ExitCode
    )

    $path = [string]$script:Options.ResultPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return }
    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        $result = [ordered]@{}
        foreach ($prop in @($json.PSObject.Properties)) { $result[[string]$prop.Name] = $prop.Value }
        $result['mode'] = $Mode
        $result['cliMode'] = $Mode
        $result['exitCode'] = $ExitCode
        if ($Mode -eq 'isolated') {
            $singleItem = ''
            $singleCategory = ''
            if (@($script:Options.Config).Count -eq 1) {
                $singleItem = [string]$script:Options.Config[0]
                try {
                    $catalog = Get-BootstrapAppTuningCatalog
                    foreach ($it in @($catalog.items)) {
                        if ([string]$it.id -eq $singleItem) {
                            $singleCategory = [string]$it.category
                            break
                        }
                    }
                } catch {
                    $singleCategory = 'config'
                }
            } elseif (@($script:Options.App).Count -eq 1) {
                $singleItem = [string]$script:Options.App[0]
                $singleCategory = 'app'
            } elseif (@($script:Options.Component).Count -eq 1) {
                $singleItem = [string]$script:Options.Component[0]
                $singleCategory = 'component'
            }
            if (-not [string]::IsNullOrWhiteSpace($singleItem)) {
                $result['item'] = $singleItem
                $result['category'] = $singleCategory
                $result['action'] = if ([bool]$script:Options.DryRun) { 'dry-run' } else { 'apply' }
                if (-not $result.Contains('changed')) { $result['changed'] = $false }
                if (-not $result.Contains('blockedReason')) {
                    $statusText = if ($result.Contains('status')) { [string]$result['status'] } else { '' }
                    $result['blockedReason'] = if ($ExitCode -ne 0 -or $statusText -in @('blocked','error','failed')) { if ($result.Contains('error')) { [string]$result['error'] } else { 'execution-failed' } } else { '' }
                }
                if (-not $result.Contains('paths')) {
                    $result['paths'] = @(
                        [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath),
                        [System.IO.Path]::GetFullPath([string]$script:Options.LogPath)
                    )
                }
                if (-not $result.Contains('nextSteps')) {
                    $nextSteps = if ([bool]$script:Options.DryRun) {
                        @('Revise o result.json e remova --dry-run para aplicar.')
                    } else {
                        @('Revise logs e rode o doctor relacionado se houver bloqueio.')
                    }
                    $result['nextSteps'] = [object[]]@($nextSteps)
                }
                if (-not $result.Contains('doctor') -or $null -eq $result['doctor']) {
                    $result['doctor'] = [ordered]@{
                        status = 'not-run'
                        reason = if ([bool]$script:Options.DryRun) { 'dry-run' } else { 'item-without-doctor-result' }
                        checks = [object[]]@()
                    }
                }
                $result['paths'] = [object[]]@($result['paths'])
                $result['nextSteps'] = [object[]]@($result['nextSteps'])
            }
        }
        if (-not $result.Contains('artifactPaths')) {
            $result['artifactPaths'] = [ordered]@{
                logPath = [System.IO.Path]::GetFullPath([string]$script:Options.LogPath)
                resultPath = [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath)
            }
        }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($path), ($result | ConvertTo-Json -Depth 14), $utf8)
    } catch {
        Write-CliOut ("[AVISO] Nao foi possivel ajustar result.json do CLI: {0}" -f $_.Exception.Message) Yellow
    }
}

function Invoke-CliBootstrapSelectionMode {
    param(
        [Parameter(Mandatory = $true)]$Options,
        [switch]$ReturnExit
    )

    $targetSummary = @()
    if (@($Options.App).Count -gt 0) { $targetSummary += ("apps={0}" -f (Join-CliOptionValues -Values $Options.App)) }
    if (@($Options.Component).Count -gt 0) { $targetSummary += ("componentes={0}" -f (Join-CliOptionValues -Values $Options.Component)) }
    if (@($Options.Config).Count -gt 0) { $targetSummary += ("configs={0}" -f (Join-CliOptionValues -Values $Options.Config)) }
    if (@($Options.ConfigCategory).Count -gt 0) { $targetSummary += ("categorias={0}" -f (Join-CliOptionValues -Values $Options.ConfigCategory)) }

    Write-Header 'PhaseZero Bootstrap - instalacao individual'
    Write-CliOut ("Selecao: {0}" -f ($targetSummary -join ' | ')) Green

    if (-not [bool]$Options.SkipDryRun) {
        Write-CliOut ''
        Write-CliOut '[1/2] Dry-run individual...' Green
        $dryArgs = New-CliIsolatedBackendArgs -Options $Options -DryRun:$true
        $dryProcess = Invoke-CliBackendProcess -ArgumentList $dryArgs -OperationName 'dry-run'
        $dryExit = [int]$dryProcess.ExitCode
        Update-CliResultFileMode -Mode 'isolated' -ExitCode $dryExit
        if ($dryExit -ne 0) {
            Write-CliOut ("[ERRO] Dry-run individual falhou (codigo {0})." -f $dryExit) Red
            Write-CliOut ("Result: {0}" -f [string]$Options.ResultPath) Yellow
            Write-CliOut ("Log:    {0}" -f [string]$Options.LogPath) Yellow
            if (-not (Test-Path -LiteralPath ([string]$Options.ResultPath))) {
                Write-CliLegacyFailureResult -Message "Dry-run individual falhou (codigo $dryExit) sem result.json do backend." -ExitCode $dryExit
            }
            if (-not $ReturnExit -and -not [bool]$Options.NonInteractive) { Pause }
            if ($ReturnExit) { return $dryExit } else { exit $dryExit }
        }
        if ([bool]$Options.DryRun) {
            Write-Header 'DRY-RUN: selecao individual validada'
            Write-CliOut ("Result:  {0}" -f [string]$Options.ResultPath) Green
            Write-CliOut ("Log:     {0}" -f [string]$Options.LogPath) Green
            Write-CliOut ("Aplicar: {0}" -f (Format-CliApplyCommand -Options $Options)) Cyan
            if ($ReturnExit) { return 0 } else { exit 0 }
        }
    }

    if (-not [bool]$Options.Yes -and -not [bool]$Options.NonInteractive) {
        Write-CliOut ''
        $confirm = ConvertTo-CliCleanReply (Read-Host 'Aplicar instalacao/configuracao individual agora? (S/N)')
        if ($confirm -notmatch '^[Ss]$') {
            Write-CliOut '[AVISO] Operacao cancelada pelo usuario.' Yellow
            if (-not $ReturnExit) { Pause }
            if ($ReturnExit) { return 0 } else { exit 0 }
        }
    }

    Write-CliOut ''
    Write-CliOut '[2/2] Aplicando selecao individual...' Green
    $installArgs = New-CliIsolatedBackendArgs -Options $Options -DryRun:$false
    $installProcess = Invoke-CliBackendProcess -ArgumentList $installArgs -OperationName 'apply'
    $installExit = [int]$installProcess.ExitCode
    Update-CliResultFileMode -Mode 'isolated' -ExitCode $installExit

    Write-CliOut ''
    if ($installExit -eq 0) {
        Write-Header 'SUCESSO: selecao individual concluida'
        Write-CliOut ("Result: {0}" -f [string]$Options.ResultPath) Green
        Write-CliOut ("Log:    {0}" -f [string]$Options.LogPath) Green
    } else {
        Write-CliOut ("[ERRO] Selecao individual falhou (codigo {0})." -f $installExit) Red
        Write-CliOut ("Result: {0}" -f [string]$Options.ResultPath) Yellow
        Write-CliOut ("Log:    {0}" -f [string]$Options.LogPath) Yellow
        Write-CliOut 'Diagnostico: .\bootstrap-ui.bat --doctor' Yellow
        if (-not (Test-Path -LiteralPath ([string]$Options.ResultPath))) {
            Write-CliLegacyFailureResult -Message "Selecao individual falhou (codigo $installExit) sem result.json do backend." -ExitCode $installExit
        }
    }
    if (-not $ReturnExit -and -not [bool]$Options.NonInteractive) { Pause }
    if ($ReturnExit) { return $installExit } else { exit $installExit }
}

function Write-CliLegacyFailureResult {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 2,
        [string]$Mode = 'legacy',
        [string]$HowToFix = 'Revise o argumento informado, rode install-cli.bat -ListProfiles e execute novamente com -Profile <nome>.'
    )

    if ([string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath)) { return }
    $payload = [ordered]@{
        status = 'error'
        mode = $Mode
        generatedAt = (Get-Date).ToString('o')
        logPath = [string]$script:Options.LogPath
        resultPath = [System.IO.Path]::GetFullPath([string]$script:Options.ResultPath)
        exitCode = $ExitCode
        error = $Message
        howToFix = $HowToFix
    }
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$script:Options.ResultPath)
}

function Invoke-CliAiToolsMode {
    param(
        [Parameter(Mandatory = $true)]$Options,
        [switch]$ReturnExit
    )

    . $ToolsPs1 -BootstrapUiLibraryMode
    $script:CliLogPath = Resolve-CliLogPath -RequestedPath ([string]$Options.LogPath)
    Write-CliLog -Message 'AI tools mode started.'

    $catalog = Get-BootstrapAiToolCatalog
    $tools = @()
    if ([bool]$Options.AllAiTools) {
        $tools = @($catalog.Keys)
    } else {
        Resolve-CliToolTerms -Options $Options -Catalog $catalog
        $tools = @($Options.Tool)
    }
    if ($tools.Count -eq 0) { throw 'Informe --tool <name> ou --all-ai-tools.' }

    $action = 'install'
    if ([bool]$Options.Uninstall) { $action = 'uninstall' }
    elseif ([bool]$Options.Start) { $action = 'start' }
    elseif ([bool]$Options.Configure) { $action = 'configure' }
    elseif ([bool]$Options.Validate) { $action = 'validate' }

    $installRoot = Get-BootstrapAiInstallRoot -InstallRoot ([string]$Options.InstallRoot)
    $results = New-Object System.Collections.Generic.List[object]
    $exitCode = 0
    foreach ($tool in @($tools)) {
        Write-CliLog -Message ("{0} {1}" -f $action, $tool)
        try {
            $result = Invoke-BootstrapAiToolAction -ToolName ([string]$tool) -Action $action -InstallRoot $installRoot -ProjectRoot $PSScriptRoot -DryRun:([bool]$Options.DryRun) -Yes:([bool]$Options.Yes) -NoAdmin:([bool]$Options.NoAdmin)
            $results.Add($result) | Out-Null
            $status = [string]$result['status']
            if ($action -in @('install','configure','start','uninstall') -and $status -in @('blocked','error','auth-failed','unhealthy','login-required')) { $exitCode = 3 }
        } catch {
            $status = if ($_.Exception.Data.Contains('BootstrapStatus')) { [string]$_.Exception.Data['BootstrapStatus'] } else { 'error' }
            $kind = if ($_.Exception.Data.Contains('BootstrapBlockerKind')) { [string]$_.Exception.Data['BootstrapBlockerKind'] } else { '' }
            $actionHint = if ($_.Exception.Data.Contains('BootstrapAction')) { [string]$_.Exception.Data['BootstrapAction'] } else { '' }
            $exitCode = if ($status -eq 'blocked') { 3 } else { 2 }
            $message = $_.Exception.Message
            Write-CliLog -Level 'ERROR' -Message $message
            $results.Add([ordered]@{
                mode        = 'ai-tools'
                tool        = [string]$tool
                action      = $action
                status      = $status
                installRoot = $installRoot
                projectRoot = $PSScriptRoot
                message     = $message
                blockerKind = $kind
                howToFix    = $actionHint
            }) | Out-Null
        }
    }

    $payload = [ordered]@{
        mode        = 'ai-tools'
        action      = $action
        dryRun      = [bool]$Options.DryRun
        yes         = [bool]$Options.Yes
        noAdmin     = [bool]$Options.NoAdmin
        installRoot = $installRoot
        logPath     = $script:CliLogPath
        results     = @($results.ToArray())
    }
    if ($results.Count -eq 1) {
        $single = $results[0]
        foreach ($key in @('tool','status','message','docs','commandPath','version','blockerKind','howToFix')) {
            if ($single -is [System.Collections.IDictionary] -and $single.Contains($key)) { $payload[$key] = $single[$key] }
        }
    }
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
    Write-CliLog -Message ("AI tools mode finished. ExitCode={0}" -f $exitCode)
    if ($ReturnExit) { return $exitCode } else { exit $exitCode }
}

$rawResultPath = Get-CliRawOptionValue -Tokens @($args) -Names @('--result-path', '-ResultPath')
$rawLogPath = Get-CliRawOptionValue -Tokens @($args) -Names @('--log-path', '-LogPath')
try {
    $script:Options = Read-CliArgs -Tokens @($args)
} catch {
    $script:Options = New-CliOptions
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    $script:Options.LogPath = if ([string]::IsNullOrWhiteSpace($rawLogPath)) { Join-Path $root ("phasezero-install-cli-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)) } else { $rawLogPath }
    $script:Options.ResultPath = if ([string]::IsNullOrWhiteSpace($rawResultPath)) { Join-Path $root ("phasezero-install-cli-{0:yyyyMMdd-HHmmss}.result.json" -f (Get-Date)) } else { $rawResultPath }
    Write-CliLegacyFailureResult -Message $_.Exception.Message -ExitCode 2 -Mode 'argument-parse' -HowToFix 'Informe valor apos a opcao ou use --help para exemplos.'
    Write-CliOut ("Result: {0}" -f [string]$script:Options.ResultPath) Yellow
    Write-CliOut ("Log:    {0}" -f [string]$script:Options.LogPath) Yellow
    exit 2
}

if ([string]::IsNullOrWhiteSpace([string]$script:Options.LogPath)) {
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    $script:Options.LogPath = Join-Path $root ("phasezero-install-cli-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}
if ([string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath)) {
    $root = if ($env:TEMP) { $env:TEMP } else { $PSScriptRoot }
    $script:Options.ResultPath = Join-Path $root ("phasezero-install-cli-{0:yyyyMMdd-HHmmss}.result.json" -f (Get-Date))
}

if ([bool]$script:Options.Help) {
    Write-CliUsage
    exit 0
}

function Invoke-CliMcpRepair {
    # Repara configs MCP dos clientes (npx puro -> cmd /c npx). Dry-run por padrao; --yes aplica.
    param([Parameter(Mandatory = $true)]$Options)

    $apply = ([bool]$Options.Yes -and -not [bool]$Options.DryRun)
    Write-CliOut ''
    Write-CliOut ("[reparo MCP] {0}..." -f $(if ($apply) { 'aplicando' } else { 'pre-visualizando (dry-run)' })) Green
    Write-CliOut ''

    $preview = Invoke-BootstrapMcpConfigRepair -DryRun
    foreach ($t in @($preview.targets)) {
        $color = if ([int]$t.fixed -gt 0) { [System.ConsoleColor]::Yellow } elseif ([string]$t.status -eq 'absent') { [System.ConsoleColor]::DarkGray } else { [System.ConsoleColor]::Green }
        Write-CliOut ("  {0,-16} {1,-10} npx-puro={2}  {3}" -f [string]$t.id, [string]$t.status, [int]$t.fixed, [string]$t.path) $color
    }
    Write-CliOut ''

    $payload = [ordered]@{
        status = 'success'
        mode = 'mcp-repair'
        action = $(if ($apply) { 'apply' } else { 'dry-run' })
        dryRun = (-not $apply)
        totalFixed = [int]$preview.totalFixed
        targets = @($preview.targets)
        verification = $null
        message = ''
        nextSteps = @()
    }

    if ([int]$preview.totalFixed -eq 0) {
        Write-CliOut 'Nenhum comando "npx" puro encontrado nos configs MCP. Nada a reparar.' Green
        $payload['message'] = 'Nenhum comando npx puro encontrado nos configs MCP.'
        $payload['nextSteps'] = @('Nada a reparar.')
        Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
        return 0
    }
    if (-not $apply) {
        Write-CliOut ("{0} entrada(s) seriam corrigidas. Para aplicar (com backup .bak): .\install-cli.bat --repair-mcp --yes" -f [int]$preview.totalFixed) Cyan
        $payload['message'] = ("{0} entrada(s) seriam corrigidas." -f [int]$preview.totalFixed)
        $payload['nextSteps'] = @('.\install-cli.bat --repair-mcp --yes')
        Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
        return 0
    }

    $result = Invoke-BootstrapMcpConfigRepair
    Write-CliOut ("[reparo MCP] {0} entrada(s) corrigida(s) (backups .bak criados)." -f [int]$result.totalFixed) Green
    $verify = Invoke-BootstrapMcpConfigRepair -DryRun
    Write-CliOut ("Verificacao: npx puros restantes = {0}" -f [int]$verify.totalFixed) $(if ([int]$verify.totalFixed -eq 0) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Yellow })

    $payload['dryRun'] = $false
    $payload['action'] = 'apply'
    $payload['totalFixed'] = [int]$result.totalFixed
    $payload['targets'] = @($result.targets)
    $payload['verification'] = $verify
    $payload['status'] = if ([int]$verify.totalFixed -eq 0) { 'success' } else { 'warning' }
    $payload['message'] = ("Reparo MCP corrigiu {0} entrada(s); restantes={1}." -f [int]$result.totalFixed, [int]$verify.totalFixed)
    $payload['nextSteps'] = @('Reinicie os apps MCP/IDE para reconectar.')
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
    return $(if ([int]$verify.totalFixed -eq 0) { 0 } else { 1 })
}

function Invoke-CliLifecycleActions {
    # Executa export/import/factory-reset (individual por --item/--app/--config ou em lote --batch).
    # Backend ja carregado em library mode. Retorna $false se nao houver acao de ciclo de vida.
    param([Parameter(Mandatory = $true)]$Options)

    $hasBatch = -not [string]::IsNullOrWhiteSpace([string]$Options.Batch)
    $hasExport = -not [string]::IsNullOrWhiteSpace([string]$Options.ExportConfig)
    $hasImport = -not [string]::IsNullOrWhiteSpace([string]$Options.ImportConfig)
    if (-not ($hasBatch -or $hasExport -or $hasImport -or [bool]$Options.FactoryReset)) { return $false }

    $dry = [bool]$Options.DryRun
    $ids = @(@($Options.App) + @($Options.Component) + @($Options.Config) + @($Options.Item) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    # Acao efetiva
    $action = if ($hasBatch) { [string]$Options.Batch } elseif ([bool]$Options.FactoryReset) { 'factory-reset' } elseif ($hasExport) { 'export' } else { 'import' }
    if ($action -notin @('export', 'import', 'factory-reset')) {
        Write-CliOut ("[ERRO] Acao de ciclo de vida invalida: {0} (use export|import|factory-reset)." -f $action) Red
        exit 2
    }
    $path = if ($action -eq 'export') { [string]$Options.ExportConfig } elseif ($action -eq 'import') { [string]$Options.ImportConfig } else { '' }

    Write-CliOut ("[ciclo de vida] acao={0} alvo={1} dry-run={2}" -f $action, $(if ($hasBatch) { 'lote(amarelos)' } else { ($ids -join ',') }), $dry) Cyan

    $result = $null
    try {
        if ($hasBatch) {
            $result = Invoke-BootstrapBatchAction -Action $action -Path $path -Ids @($ids) -IncludeSecrets:([bool]$Options.IncludeSecrets) -DryRun:$dry
        } else {
            if (@($ids).Count -eq 0) {
                Write-CliOut '[ERRO] Informe o item com --item/--app/--config (ou use --batch para todos os amarelos).' Red
                exit 2
            }
            $items = New-Object System.Collections.Generic.List[object]
            foreach ($id in $ids) {
                $r = Invoke-BootstrapItemAction -Id $id -Action $action -Path $path -IncludeSecrets:([bool]$Options.IncludeSecrets) -DryRun:$dry
                $items.Add([ordered]@{ id = $id; status = [string]$r.status; detail = $r }) | Out-Null
                Write-CliOut ("  {0}: {1}" -f $id, [string]$r.status) $(if ([string]$r.status -in @('exported','imported','reverted','planned')) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Yellow })
            }
            $result = [ordered]@{ action = $action; count = @($ids).Count; results = @($items.ToArray()) }
        }
    } catch {
        Write-CliOut ("[ERRO] Ciclo de vida falhou: {0}" -f $_.Exception.Message) Red
        Write-CliJsonResult -Payload ([ordered]@{
            status = 'error'
            mode = 'config-lifecycle'
            action = $action
            dryRun = $dry
            error = $_.Exception.Message
            howToFix = 'Revise item/path informado e rode --list-items para confirmar o alvo.'
        }) -ResultPath ([string]$Options.ResultPath)
        exit 1
    }

    $payload = [ordered]@{
        status = 'success'
        mode = 'config-lifecycle'
        action = $action
        dryRun = $dry
        count = $(if ($result -is [System.Collections.IDictionary] -and $result.Contains('count')) { [int]$result['count'] } else { @($ids).Count })
        result = $result
        message = '[ciclo de vida] concluido.'
    }
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$Options.ResultPath)
    Write-CliOut '[ciclo de vida] concluido.' Green
    return $true
}

if (-not (Test-Path -LiteralPath $ToolsPs1)) {
    Write-CliOut '[ERRO] Nao encontrado:' Red
    Write-CliOut "  $ToolsPs1"
    Write-CliOut 'Execute a partir da pasta do repositorio.' Red
    if (-not [bool]$script:Options.NonInteractive) { Pause }
    exit 1
}

if ([bool]$script:Options.ListTools) {
    . $ToolsPs1 -BootstrapUiLibraryMode
    Write-CliOut '[1/1] AI tools e proxies disponiveis...' Green
    Write-CliOut ''
    Write-CliCatalogEntries -Kind 'tool'
    exit 0
}

if ([bool]$script:Options.ListItems) {
    . $ToolsPs1 -BootstrapUiLibraryMode
    Write-CliOut '[1/1] Catalogo unificado...' Green
    Write-CliOut ''
    Write-CliUnifiedCatalogEntries
    exit 0
}

if ([bool]$script:Options.AllAiTools -or @($script:Options.Tool).Count -gt 0) {
    Invoke-CliAiToolsMode -Options $script:Options
}

Write-Header 'PhaseZero Bootstrap - instalador CLI'

try {
    . $ToolsPs1 -BootstrapUiLibraryMode
    $profiles = Get-BootstrapProfileCatalog
} catch {
    Write-CliOut "[ERRO] Falha ao carregar catalogo: $($_.Exception.Message)"
    if (-not [bool]$script:Options.NonInteractive) { Pause }
    exit 1
}

# Reparo de configs MCP (npx puro -> cmd /c npx) nos clientes. --repair-mcp mostra o plano (dry-run);
# adicione --yes para aplicar de fato (com backup .bak por arquivo).
if ([bool]$script:Options.RepairMcp) {
    exit (Invoke-CliMcpRepair -Options $script:Options)
}

# Verificacao de drift: roda o Doctor e compara com o baseline, reportando regressoes.
if ([bool]$script:Options.DriftCheck) {
    Write-CliOut ''
    Write-CliOut '[drift] verificando (Doctor + comparacao com baseline)...' Green
    $drift = Invoke-BootstrapDriftCheck
    if (-not $drift.baselineExisted) {
        Write-CliOut 'Baseline criado agora (primeira referencia). Rode de novo depois para detectar regressoes.' Cyan
    } elseif ([int]$drift.regressionCount -eq 0) {
        Write-CliOut 'Nenhuma regressao desde o baseline. Tudo estavel.' Green
    } else {
        Write-CliOut ("{0} regressao(oes):" -f [int]$drift.regressionCount) Yellow
        foreach ($r in @($drift.regressions)) { Write-CliOut ("  {0}: {1} -> {2}" -f [string]$r.id, [string]$r.from, [string]$r.to) Yellow }
    }
    $payload = [ordered]@{
        status = $(if ([int]$drift.regressionCount -gt 0) { 'warning' } else { 'success' })
        mode = 'drift-check'
        dryRun = $true
        drift = $drift
        message = $(if (-not $drift.baselineExisted) { 'Baseline criado agora.' } elseif ([int]$drift.regressionCount -eq 0) { 'Nenhuma regressao desde o baseline.' } else { ("{0} regressao(oes)." -f [int]$drift.regressionCount) })
    }
    Write-CliJsonResult -Payload $payload -ResultPath ([string]$script:Options.ResultPath)
    exit 0
}

# Acoes de ciclo de vida de configuracao (export/import/factory-reset, individual ou em lote).
if (Invoke-CliLifecycleActions -Options $script:Options) { exit 0 }

# Atalho amigavel: instalar todos os Web Apps de uma unica vez (reusa o perfil webapps).
if ([bool]$script:Options.InstallWebapps -and [string]::IsNullOrWhiteSpace([string]$script:Options.Profile)) {
    $script:Options.Profile = 'webapps'
    Write-CliOut '[web apps] instalando todos via perfil "webapps".' Green
}

try {
    Resolve-CliUnifiedItemTerms -Options $script:Options
} catch {
    Write-CliOut ("[ERRO] {0}" -f $_.Exception.Message) Red
    Write-CliOut 'Listar tudo:        .\install-cli.bat --list-items' Yellow
    Write-CliOut 'Listar apps:        .\install-cli.bat --list-apps' Yellow
    Write-CliOut 'Listar configs:     .\install-cli.bat --list-configs' Yellow
    Write-CliOut 'Listar AI tools:    .\install-cli.bat --list-tools' Yellow
    Write-CliLegacyFailureResult -Message $_.Exception.Message -ExitCode 2 -Mode 'isolated-selection' -HowToFix 'Rode install-cli.bat --list-items e use numero global, ID, alias ou nome exato com --item.'
    Write-CliOut ("Result: {0}" -f [string]$script:Options.ResultPath) Yellow
    Write-CliOut ("Log:    {0}" -f [string]$script:Options.LogPath) Yellow
    Write-CliOut 'Proximo passo: rode .\install-cli.bat --list-items' Yellow
    if (-not [bool]$script:Options.NonInteractive) { Pause }
    exit 2
}

if (@($script:Options.Tool).Count -gt 0 -and -not (Test-CliHasBootstrapSelection -Options $script:Options)) {
    Invoke-CliAiToolsMode -Options $script:Options
}

if ([bool]$script:Options.ListProfiles) {
    Write-CliOut '[1/3] Carregando perfis disponiveis...' Green
    Write-CliOut ''
    Write-CliProfileCatalog -Profiles $profiles
    exit 0
}

if ([bool]$script:Options.ListApps) {
    Write-CliOut '[1/1] Apps individuais disponiveis...' Green
    Write-CliOut ''
    Write-CliCatalogEntries -Kind 'app'
    exit 0
}

if ([bool]$script:Options.ListConfigs) {
    Write-CliOut '[1/1] Configuracoes disponiveis...' Green
    Write-CliOut ''
    Write-CliCatalogEntries -Kind 'config'
    exit 0
}

try {
    Resolve-CliOptionTerms -Options $script:Options
} catch {
    Write-CliOut ("[ERRO] {0}" -f $_.Exception.Message) Red
    Write-CliOut 'Listar tudo:        .\install-cli.bat --list-items' Yellow
    Write-CliOut 'Listar apps:        .\install-cli.bat --list-apps' Yellow
    Write-CliOut 'Listar configs:     .\install-cli.bat --list-configs' Yellow
    Write-CliOut 'Listar AI tools:    .\install-cli.bat --list-tools' Yellow
    Write-CliLegacyFailureResult -Message $_.Exception.Message -ExitCode 2 -Mode 'isolated-selection' -HowToFix 'Rode install-cli.bat --list-items ou o catalogo especifico e use numero, ID, alias ou nome exato.'
    Write-CliOut ("Result: {0}" -f [string]$script:Options.ResultPath) Yellow
    Write-CliOut ("Log:    {0}" -f [string]$script:Options.LogPath) Yellow
    Write-CliOut 'Proximo passo: corrija a selecao usando o catalogo exibido.' Yellow
    if (-not [bool]$script:Options.NonInteractive) { Pause }
    exit 2
}

if (Test-CliHasBootstrapSelection -Options $script:Options) {
    Invoke-CliBootstrapSelectionMode -Options $script:Options
}

$profileChoice = [string]$script:Options.Profile
if ([string]::IsNullOrWhiteSpace($profileChoice)) {
    if ([bool]$script:Options.NonInteractive) {
        Write-CliOut '[ERRO] -Profile e obrigatorio em modo nao-interativo.' Red
        Write-CliOut 'Uso: .\install-cli.ps1 -Profile <nome> -NonInteractive' Yellow
        Write-CliOut 'Listar perfis: .\install-cli.ps1 -ListProfiles' Yellow
        Write-CliLegacyFailureResult -Message '-Profile e obrigatorio em modo nao-interativo.' -ExitCode 2
        exit 2
    }

    # Laco de menu: cada acao executa e retorna ao menu; somente "Sair" encerra o processo.
    # (Em PowerShell, 'continue/break' dentro de switch nao controlam o while; por isso cada
    # case termina naturalmente e o while reitera, e apenas os cases de saida chamam exit.)
    while ($true) {
        $menuChoice = Show-CliMainMenu
        switch ($menuChoice) {
            '1' {
                [void](Invoke-CliMenuBackendIntent -Intent 'Doctor')
                Pause
            }
            '2' {
                [void](Invoke-CliMenuBackendIntent -Intent 'SupportBundle')
                Pause
            }
            '3' {
                [void](Invoke-CliMenuProfileFlow -Options $script:Options -Profiles $profiles)
                Pause
            }
            '4' {
                $entry = Read-CliCatalogSelection -Kind 'app'
                if ($null -eq $entry) {
                    Write-CliOut '[AVISO] Nenhum app selecionado.' Yellow
                } else {
                    $script:Options.App = @([string]$entry.id)
                    [void](Invoke-CliBootstrapSelectionMode -Options $script:Options -ReturnExit)
                    $script:Options.App = @()
                }
                Pause
            }
            '5' {
                $entry = Read-CliCatalogSelection -Kind 'config'
                if ($null -eq $entry) {
                    Write-CliOut '[AVISO] Nenhuma configuracao selecionada.' Yellow
                } else {
                    $script:Options.Config = @([string]$entry.id)
                    [void](Invoke-CliBootstrapSelectionMode -Options $script:Options -ReturnExit)
                    $script:Options.Config = @()
                }
                Pause
            }
            '6' {
                $entry = Read-CliCatalogSelection -Kind 'tool'
                if ($null -eq $entry) {
                    Write-CliOut '[AVISO] Nenhuma AI tool selecionada.' Yellow
                } else {
                    $script:Options.Tool = @([string]$entry.id)
                    $script:Options.Start = $true
                    [void](Invoke-CliAiToolsMode -Options $script:Options -ReturnExit)
                    $script:Options.Tool = @()
                    $script:Options.Start = $false
                }
                Pause
            }
            '0' { exit 0 }
            '' { exit 0 }
            default {
                Write-CliOut '[AVISO] Opcao invalida.' Yellow
                Pause
            }
        }
    }
}

Write-CliOut ''
Write-CliOut ("[1/3] Perfil selecionado: {0}" -f $profileChoice) Green

if ([bool]$script:Options.DryRun) { $script:Options.SkipDryRun = $false }

if (-not [bool]$script:Options.SkipDryRun) {
    Write-CliOut ''
    Write-CliOut "[2/3] Validando selecao: $profileChoice"
    Write-CliOut ''

    $dryArgs = Add-CliBackendArtifactArg -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ToolsPs1,
        '-Profile', $profileChoice,
        '-DryRun', '-NonInteractive', '-SkipManualRequirements'
    )
    $process = Invoke-CliBackendProcess -ArgumentList $dryArgs -OperationName 'dry-run'
    $dryExit = $process.ExitCode

    if ($dryExit -ne 0) {
        Write-CliOut ''
        Write-CliOut "[ERRO] Dry-run falhou (codigo $dryExit)."
        Write-CliOut ("Log:        {0}" -f [string]$script:Options.LogPath) Yellow
        Write-CliOut ("Result:     {0}" -f [string]$script:Options.ResultPath) Yellow
        Write-CliOut ("Retomar:    .\install-cli.bat -Profile {0} -DryRun" -f $profileChoice) Yellow
        Write-CliOut ("Diagnostico:.\bootstrap-ui.bat --doctor") Yellow
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath) -and -not (Test-Path -LiteralPath ([string]$script:Options.ResultPath))) {
            Write-CliLegacyFailureResult -Message "Dry-run falhou (codigo $dryExit) sem result.json do backend." -ExitCode $dryExit
        }
        if (-not [bool]$script:Options.NonInteractive) { Pause }
        exit $dryExit
    }
    if ([bool]$script:Options.DryRun) {
        Write-Header 'DRY-RUN: validacao concluida'
        Write-CliOut ("Result:    {0}" -f [string]$script:Options.ResultPath) Green
        Write-CliOut ("Log:       {0}" -f [string]$script:Options.LogPath) Green
        Write-CliOut ("Aplicar:   .\install-cli.bat -Profile {0}" -f $profileChoice) Cyan
        exit 0
    }
}

if (-not [bool]$script:Options.NonInteractive) {
    Write-CliOut ''
    $confirm = ConvertTo-CliCleanReply (Read-Host 'Deseja prosseguir com a instalacao real? (S/N)')
    if ($confirm -notmatch '^[Ss]$') {
        Write-CliOut '[AVISO] Instalacao cancelada pelo usuario.' Yellow
        Pause
        exit 0
    }
}

Write-CliOut ''
Write-CliOut "[3/3] Iniciando instalacao do perfil: $profileChoice"
Write-CliOut 'Isso pode levar varios minutos dependendo das dependencias...' Yellow
Write-CliOut ''

$installArgs = Add-CliBackendArtifactArg -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $ToolsPs1,
    '-Profile', $profileChoice,
    '-NonInteractive', '-SkipManualRequirements'
)
$installProcess = Invoke-CliBackendProcess -ArgumentList $installArgs -OperationName 'apply'
$installExit = $installProcess.ExitCode

Write-CliOut ''
if ($installExit -eq 0) {
    Write-Header 'SUCESSO: Instalacao concluida!'
    Write-CliOut ("Result:    {0}" -f [string]$script:Options.ResultPath) Green
    Write-CliOut ("Log:       {0}" -f [string]$script:Options.LogPath) Green
} else {
    Write-CliOut ("[ERRO] A instalacao falhou ou foi interrompida (ExitCode: {0})." -f $installExit) Red
    Write-CliOut ("Log:          {0}" -f [string]$script:Options.LogPath) Yellow
    Write-CliOut ("Result:       {0}" -f [string]$script:Options.ResultPath) Yellow
    Write-CliOut ("Retomar:      .\install-cli.bat -Profile {0}" -f $profileChoice) Yellow
    Write-CliOut ("Diagnostico:  .\bootstrap-ui.bat --doctor") Yellow
    Write-CliOut ("Bundle:       .\bootstrap-ui.bat --support-bundle") Yellow
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Options.ResultPath) -and -not (Test-Path -LiteralPath ([string]$script:Options.ResultPath))) {
        Write-CliLegacyFailureResult -Message "Instalacao falhou ou foi interrompida sem result.json do backend." -ExitCode $installExit
    }
}

if (-not [bool]$script:Options.NonInteractive) { Pause }
exit $installExit
