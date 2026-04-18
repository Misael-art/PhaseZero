param(
    [string]$CloneBaseDir,
    [string]$WorkspaceRoot = 'F:\Steam\Steamapps',
    [string[]]$Profile = @(),
    [string[]]$Component = @(),
    [string[]]$Exclude = @(),
    [ValidateSet('Auto', 'LCD', 'OLED')][string]$SteamDeckVersion = 'Auto',
    [string]$HostHealth,
    [string]$LogPath,
    [string]$ResultPath,
    [switch]$Interactive,
    [switch]$ListProfiles,
    [switch]$ListHostHealthModes,
    [switch]$ListComponents,
    [switch]$UiContractJson,
    [switch]$BootstrapUiLibraryMode,
    [switch]$DryRun,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [Console]::OutputEncoding

$script:StartTime = Get-Date
$script:LogPath = if ([string]::IsNullOrWhiteSpace($LogPath)) {
    Join-Path $env:TEMP ("bootstrap-tools_{0:yyyyMMdd_HHmmss}.log" -f $script:StartTime)
} else {
    $LogPath
}
$script:ResultPath = $ResultPath

$script:LogParent = Split-Path -Path $script:LogPath -Parent
if ($script:LogParent) {
    $null = New-Item -Path $script:LogParent -ItemType Directory -Force
}

try {
    $sp = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12
} catch {
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $script:LogPath -Value $line -Encoding utf8
    Write-Host $line
}

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Invoke-NativeWithLog {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Args = @()
    )

    $hasNativePreferenceVar = $false
    $oldNativePreference = $null
    $nativePrefVar = Get-Variable -Name 'PSNativeCommandUseErrorActionPreference' -ErrorAction SilentlyContinue
    if ($nativePrefVar) {
        $hasNativePreferenceVar = $true
        $oldNativePreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        & $Exe @Args 2>&1 | ForEach-Object {
            $line = [string]$_
            if ($line -match "`0") { $line = $line -replace "`0", '' }
            Add-Content -Path $script:LogPath -Value $line -Encoding utf8
            Write-Host $line
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        if ($hasNativePreferenceVar) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }
}

function Ensure-PathUserContains {
    param([Parameter(Mandatory = $true)][string]$Dir)
    if (-not $Dir) { return }
    $Dir = $Dir.Trim().TrimEnd('\')
    if (-not (Test-Path $Dir)) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $parts = $userPath -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ -ne '' }
    $exists = $parts | Where-Object { $_ -ieq $Dir } | Select-Object -First 1
    if (-not $exists) {
        $newUserPath = ($userPath.TrimEnd(';') + ';' + $Dir).Trim(';')
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        Write-Log "Adicionado ao PATH (Usuário): $Dir"
    } else {
        Write-Log "Já está no PATH (Usuário): $Dir"
    }
    Refresh-SessionPath
    if (($env:Path -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') }) -inotcontains $Dir) {
        $env:Path = ($env:Path.TrimEnd(';') + ';' + $Dir).Trim(';')
    }
}

function Ensure-PathUserContainsFirst {
    param([Parameter(Mandatory = $true)][string]$Dir)
    if (-not $Dir) { return }
    $Dir = $Dir.Trim().TrimEnd('\')
    if (-not (Test-Path $Dir)) { return }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $parts = $userPath -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ -ne '' }
    $parts = @($parts | Where-Object { $_ -ine $Dir })

    $newUserPath = (@($Dir) + $parts) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Write-Log "Priorizado no PATH (Usuário): $Dir"

    Refresh-SessionPath
}

function Ensure-PathUserPrioritize {
    param([Parameter(Mandatory = $true)][string[]]$Dirs)
    $clean = @()
    foreach ($d in $Dirs) {
        if (-not $d) { continue }
        $dd = $d.Trim().TrimEnd('\')
        if (-not $dd) { continue }
        if (-not (Test-Path $dd)) { continue }
        if ($clean -inotcontains $dd) { $clean += $dd }
    }
    if (-not $clean -or $clean.Count -eq 0) { return }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $parts = $userPath -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ -ne '' }
    foreach ($d in $clean) { $parts = @($parts | Where-Object { $_ -ine $d }) }

    $newUserPath = ($clean + $parts) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Write-Log ("Python PATH priorizado (Usuário): " + ($clean -join '; '))
    Refresh-SessionPath
}

function Ensure-PythonPathHealthy {
    param([Parameter(Mandatory = $true)][string]$PythonExe)
    if (-not $PythonExe) { return }
    if (-not (Test-Path $PythonExe)) { return }
    if ($PythonExe -match '\\Microsoft\\WindowsApps\\') { return }

    $pythonDir = Split-Path $PythonExe -Parent
    $scriptsDir = Join-Path $pythonDir 'Scripts'
    Ensure-PathUserPrioritize -Dirs @($scriptsDir, $pythonDir)

    $resolved = Resolve-CommandPath -Name 'python'
    if ($resolved -and ($resolved -match '\\Microsoft\\WindowsApps\\')) {
        Write-Log "python ainda resolve para WindowsApps após priorização: $resolved" 'WARN'
    }
}

function Set-UserEnvVar {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $current = [Environment]::GetEnvironmentVariable($Name, 'User')
    if ($current -ne $Value) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        Write-Log "Definido $Name (Usuário) = $Value"
    } else {
        Write-Log "Já definido $Name (Usuário) = $Value"
    }
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Ensure-ProxyEnvFromWinHttp {
    $raw = $null
    try {
        $raw = & netsh winhttp show proxy 2>&1
    } catch {
        $raw = $null
    }
    if (-not $raw) { return }

    $text = ($raw | Out-String)
    if ($text -match 'Direct access') { return }

    $proxyLine = ($raw | Where-Object { $_ -match 'Proxy Server\\(s\\)' } | Select-Object -First 1)
    if (-not $proxyLine) { return }

    $proxy = ($proxyLine -replace '^.*Proxy Server\\(s\\)\\s*:\\s*', '').Trim()
    if (-not $proxy) { return }

    $httpProxy = $null
    $httpsProxy = $null
    if ($proxy -match 'http\\s*=\\s*([^;\\s]+)') { $httpProxy = $Matches[1] }
    if ($proxy -match 'https\\s*=\\s*([^;\\s]+)') { $httpsProxy = $Matches[1] }
    if (-not $httpProxy -and -not $httpsProxy) {
        $httpProxy = $proxy
        $httpsProxy = $proxy
    }

    if (-not $env:HTTP_PROXY -and $httpProxy) {
        $env:HTTP_PROXY = $httpProxy
        Write-Log "Detectado proxy (WinHTTP) -> HTTP_PROXY=$httpProxy"
    }
    if (-not $env:HTTPS_PROXY -and $httpsProxy) {
        $env:HTTPS_PROXY = $httpsProxy
        Write-Log "Detectado proxy (WinHTTP) -> HTTPS_PROXY=$httpsProxy"
    }

    $bypassLine = ($raw | Where-Object { $_ -match 'Bypass List' } | Select-Object -First 1)
    if ($bypassLine -and -not $env:NO_PROXY) {
        $bypass = ($bypassLine -replace '^.*Bypass List\\s*:\\s*', '').Trim()
        if ($bypass -and ($bypass -notmatch 'None')) {
            $env:NO_PROXY = ($bypass -replace ';', ',')
            Write-Log "Detectado proxy bypass (WinHTTP) -> NO_PROXY=$($env:NO_PROXY)"
        }
    }
}

function Get-ClaudeHookConfigCandidatePaths {
    $candidates = @()

    if ($env:APPDATA) {
        $candidates += (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Claude\claude_desktop_config.json')
    }

    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE '.claude\settings.json')
    }
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot '.claude\settings.json')
    }

    $projectRoots = @()
    if ($env:USERPROFILE) {
        $projectRoots += (Join-Path $env:USERPROFILE 'Documents')
        $projectRoots += (Join-Path $env:USERPROFILE 'Projects')
        $projectRoots += (Join-Path $env:USERPROFILE 'Work')
        $projectRoots += (Join-Path $env:USERPROFILE 'Workspace')
        $projectRoots += (Join-Path $env:USERPROFILE 'Source')
    }
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
        foreach ($d in $drives) {
            if ($d -and $d.Root) {
                $projectRoots += (Join-Path $d.Root 'Projects')
                $projectRoots += (Join-Path $d.Root 'Work')
                $projectRoots += (Join-Path $d.Root 'Workspace')
                $projectRoots += (Join-Path $d.Root 'Source')
            }
        }
    } catch {
    }

    foreach ($root in ($projectRoots | Select-Object -Unique)) {
        if (-not $root) { continue }
        if (-not (Test-Path $root)) { continue }

        $level1 = @()
        try {
            $level1 = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Select-Object -First 200
        } catch {
            $level1 = @()
        }
        foreach ($d1 in $level1) {
            $p1 = Join-Path $d1.FullName '.claude\settings.json'
            if (Test-Path $p1) { $candidates += $p1 }

            $level2 = @()
            try {
                $level2 = Get-ChildItem -Path $d1.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 50
            } catch {
                $level2 = @()
            }
            foreach ($d2 in $level2) {
                $p2 = Join-Path $d2.FullName '.claude\settings.json'
                if (Test-Path $p2) { $candidates += $p2 }
            }
        }
    }

    $existing = @()
    foreach ($p in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path $p) { $existing += (Get-Item $p).FullName }
    }
    return @($existing | Select-Object -Unique)
}

function Backup-FileWithTimestamp {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $bak = "$Path.bak_$stamp"
    Copy-Item -Path $Path -Destination $bak -Force
    return $bak
}

function Quote-WindowsPathTokensInString {
    param([Parameter(Mandatory = $true)][string]$Text)
    $pattern = '(?<!["''])([A-Za-z]:\\[^"'']*?\.(?:exe|cmd|bat|ps1))(?!["''])'
    try {
        return [regex]::Replace($Text, $pattern, { param($m) '"' + $m.Groups[1].Value + '"' })
    } catch {
        return $Text
    }
}

function Convert-HookItemIfNeeded {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [string]$GitBashPath
    )

    if ($Item -is [string]) {
        $s = [string]$Item
        if ($s -match '(?i)(^|\\s)/usr/bin/bash(\\s|$)' -or $s -match '(?i)(^|\\s)/bin/bash(\\s|$)' -or $s -match '(?i)\\bbash\\b') {
            return $null
        }
        if ($s -match '(?i)C:\\\\Program Files\\\\' -and ($s -notmatch '(?i)\"C:\\\\Program Files\\\\')) {
            return $null
        }
        return $Item
    }

    $cmd = $null
    $args = $null
    try { $cmd = $Item.command } catch { $cmd = $null }
    try { $args = $Item.args } catch { $args = $null }

    if ($cmd -and ($cmd -match '(?i)^/usr/bin/bash(\\s|$)' -or $cmd -match '(?i)^/bin/bash(\\s|$)')) {
        if (-not $GitBashPath -or -not (Test-Path $GitBashPath)) { return $null }

        $scriptText = $null
        $m = [regex]::Match($cmd, '(?i)^(?:/usr/bin/bash|/bin/bash)\\s+-(?:l?c)\\s+(.+)$')
        if ($m.Success) {
            $scriptText = $m.Groups[1].Value.Trim()
        } elseif ($args -and ($args -is [System.Collections.IEnumerable])) {
            $arr = @($args)
            if ($arr.Count -ge 2 -and ($arr[0] -match '^-l?c$')) {
                $scriptText = [string]$arr[1]
            }
        }

        if (-not $scriptText) { return $null }
        $scriptText = Quote-WindowsPathTokensInString -Text $scriptText

        $Item.command = $GitBashPath
        $Item.args = @('-lc', $scriptText)
        return $Item
    }

    if ($args -and ($args -is [System.Collections.IEnumerable])) {
        $arr = @()
        foreach ($a in @($args)) {
            if ($a -is [string]) { $arr += (Quote-WindowsPathTokensInString -Text ([string]$a)) } else { $arr += $a }
        }
        try { $Item.args = $arr } catch { }
    }

    $cmdStr = $null
    if ($cmd -is [string]) { $cmdStr = [string]$cmd }
    if ($cmdStr -and ($cmdStr -match '(?i)\\bbash\\b') -and ($cmdStr -match '(?i)C:\\\\Program Files\\\\') -and ($cmdStr -notmatch '(?i)\"C:\\\\Program Files\\\\')) {
        return $null
    }
    return $Item
}

function Ensure-ClaudeHookConfigsHealthy {
    param([string]$GitBashPath)

    $paths = @(Get-ClaudeHookConfigCandidatePaths)
    if ($paths.Count -eq 0) {
        Write-Log 'Nenhum arquivo de configuração de hooks do Claude encontrado para validar.' 'INFO'
        return
    }

    foreach ($path in $paths) {
        $raw = $null
        try {
            $raw = Get-Content -Path $path -Raw -Encoding utf8
        } catch {
            Write-Log "Falha ao ler config de hooks: $path" 'WARN'
            continue
        }

        $obj = $null
        try {
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log "Config de hooks não é JSON válido: $path" 'WARN'
            continue
        }

        $hooks = $null
        try { $hooks = $obj.hooks } catch { $hooks = $null }
        if (-not $hooks) { continue }

        $changed = $false
        foreach ($k in @('SessionStart', 'UserPromptSubmit', 'Stop')) {
            $arr = $null
            try { $arr = $hooks.$k } catch { $arr = $null }
            if (-not $arr) { continue }

            $newArr = @()
            foreach ($item in @($arr)) {
                $fixed = Convert-HookItemIfNeeded -Item $item -GitBashPath $GitBashPath
                if ($null -ne $fixed) {
                    $newArr += $fixed
                } else {
                    $changed = $true
                    Write-Log "Hook inválido removido ($k) em $path" 'WARN'
                }
            }

            if ($newArr.Count -ne @($arr).Count) {
                try { $hooks.$k = $newArr } catch { }
            }
        }

        if ($changed) {
            $bak = Backup-FileWithTimestamp -Path $path
            Write-Log "Backup criado: $bak"
            try {
                $json = $obj | ConvertTo-Json -Depth 50
                Set-Content -Path $path -Value $json -Encoding utf8
                Write-Log "Config de hooks corrigida: $path"
            } catch {
                Write-Log "Falha ao salvar config de hooks corrigida: $path" 'ERROR'
            }
        } else {
            Write-Log "Config de hooks OK: $path"
        }
    }
}

function Ensure-ClaudeCodeDefaults {
    param([string]$GitBashPath)

    if (-not $env:USERPROFILE) { return }
    $settingsDir = Join-Path $env:USERPROFILE '.claude'
    $settingsPath = Join-Path $settingsDir 'settings.json'
    $null = New-Item -Path $settingsDir -ItemType Directory -Force

    $raw = $null
    $obj = $null
    if (Test-Path $settingsPath) {
        try {
            $raw = Get-Content -Path $settingsPath -Raw -Encoding utf8
        } catch {
            $raw = $null
        }
        if ($raw) {
            try {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $bak = Backup-FileWithTimestamp -Path $settingsPath
                Write-Log "settings.json inválido; backup criado: $bak" 'WARN'
                $obj = $null
            }
        }
    }
    if (-not $obj) { $obj = [pscustomobject]@{} }
    if (($obj -isnot [pscustomobject]) -and ($obj -isnot [hashtable])) {
        if (Test-Path $settingsPath) {
            $bak = Backup-FileWithTimestamp -Path $settingsPath
            Write-Log "settings.json com formato inválido; backup criado: $bak" 'WARN'
        }
        $obj = [pscustomobject]@{}
    }

    $changed = $false
    function Ensure-PropValue {
        param(
            [Parameter(Mandatory = $true)]$Target,
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)]$Value
        )
        $prop = $null
        try { $prop = [System.Management.Automation.PSObject]::AsPSObject($Target).Properties[$Name] } catch { $prop = $null }
        $exists = ($null -ne $prop)
        $current = $null
        if ($exists) {
            try { $current = $prop.Value } catch { $current = $null }
        }
        if ((-not $exists) -or ($current -ne $Value)) {
            $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
            Set-Variable -Name changed -Value $true -Scope 1
        }
    }
    function Ensure-ObjectProp {
        param(
            [Parameter(Mandatory = $true)]$Target,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $v = $null
        try { $v = $Target.$Name } catch { $v = $null }
        if ((-not $v) -or (($v -isnot [pscustomobject]) -and ($v -isnot [hashtable]))) {
            $v = [pscustomobject]@{}
            $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $v -Force
            Set-Variable -Name changed -Value $true -Scope 1
        }
        return $v
    }
    function Ensure-StringArrayProp {
        param(
            [Parameter(Mandatory = $true)]$Target,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $v = $null
        try { $v = $Target.$Name } catch { $v = $null }
        if ($v -is [string]) {
            $v = @([string]$v)
            $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $v -Force
            Set-Variable -Name changed -Value $true -Scope 1
        } elseif (-not ($v -is [System.Collections.IEnumerable])) {
            $v = @()
            $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $v -Force
            Set-Variable -Name changed -Value $true -Scope 1
        }
        return @($v)
    }
    function Merge-StringArrayUniqueCI {
        param(
            [string[]]$Existing,
            [string[]]$Add
        )
        $set = @{}
        $out = @()
        foreach ($x in @($Existing)) {
            if (-not $x) { continue }
            $k = $x.ToLowerInvariant()
            if (-not $set.ContainsKey($k)) { $set[$k] = $true; $out += $x }
        }
        foreach ($x in @($Add)) {
            if (-not $x) { continue }
            $k = $x.ToLowerInvariant()
            if (-not $set.ContainsKey($k)) { $set[$k] = $true; $out += $x }
        }
        return $out
    }

    Ensure-PropValue -Target $obj -Name '$schema' -Value 'https://json.schemastore.org/claude-code-settings.json'

    $envObj = Ensure-ObjectProp -Target $obj -Name 'env'
    Ensure-PropValue -Target $envObj -Name 'CLAUDE_CODE_USE_POWERSHELL_TOOL' -Value '1'
    Ensure-PropValue -Target $envObj -Name 'CLAUDE_CODE_EFFORT_LEVEL' -Value 'xhigh'

    $permObj = Ensure-ObjectProp -Target $obj -Name 'permissions'
    Ensure-PropValue -Target $permObj -Name 'defaultMode' -Value 'acceptEdits'

    $allow = Ensure-StringArrayProp -Target $permObj -Name 'allow'
    $deny = Ensure-StringArrayProp -Target $permObj -Name 'deny'

    $allowWanted = @(
        'Bash'
    )

    $denyWanted = @(
        'Read(.env)',
        'Read(.env.*)',
        'Read(secrets/**)',
        'Read(**/.env)',
        'Read(**/.env.*)',
        'Read(**/secrets/**)'
    )

    $newAllow = Merge-StringArrayUniqueCI -Existing $allow -Add $allowWanted
    $allowNeedsUpdate = ($allow -is [string]) -or (@($newAllow).Count -ne @($allow).Count)
    if ($allowNeedsUpdate) {
        $permObj | Add-Member -NotePropertyName 'allow' -NotePropertyValue @($newAllow) -Force
        $changed = $true
    }

    $newDeny = Merge-StringArrayUniqueCI -Existing $deny -Add $denyWanted
    if (@($newDeny).Count -ne @($deny).Count) {
        $permObj | Add-Member -NotePropertyName 'deny' -NotePropertyValue $newDeny -Force
        $changed = $true
    }

    if ($changed) {
        if (Test-Path $settingsPath) {
            $bak = Backup-FileWithTimestamp -Path $settingsPath
            Write-Log "Backup criado: $bak"
        }
        try {
            $json = $obj | ConvertTo-Json -Depth 50
            Set-Content -Path $settingsPath -Value $json -Encoding utf8
            Write-Log "Claude Code defaults aplicados: $settingsPath"
        } catch {
            Write-Log "Falha ao aplicar defaults do Claude Code em: $settingsPath" 'WARN'
        }
    } else {
        Write-Log "Claude Code defaults já configurados: $settingsPath"
    }
}

function Get-WindowsOptionalFeatureState {
    param([Parameter(Mandatory = $true)][string]$FeatureName)
    try {
        $out = & dism.exe /online /Get-FeatureInfo /FeatureName:$FeatureName 2>&1
        if (-not $out) { return 'Unknown' }
        $text = ($out | Out-String)
        if ($text -match '(?im)^\\s*State\\s*:\\s*Enabled\\s*$') { return 'Enabled' }
        if ($text -match '(?im)^\\s*Estado\\s*:\\s*Habilitado\\s*$') { return 'Enabled' }
        if ($text -match '(?im)^\\s*State\\s*:\\s*Enable Pending\\s*$') { return 'EnablePending' }
        if ($text -match '(?im)^\\s*Estado\\s*:\\s*Habilita(ç|c)ão Pendente\\s*$') { return 'EnablePending' }
        if ($text -match '(?im)^\\s*State\\s*:\\s*Disabled\\s*$') { return 'Disabled' }
        if ($text -match '(?im)^\\s*Estado\\s*:\\s*Desabilitado\\s*$') { return 'Disabled' }
        return 'Unknown'
    } catch {
        return 'Unknown'
    }
}

function Ensure-WindowsOptionalFeatureEnabled {
    param(
        [Parameter(Mandatory = $true)][string]$FeatureName,
        [string]$DisplayName = $FeatureName
    )

    $state = Get-WindowsOptionalFeatureState -FeatureName $FeatureName
    if ($state -eq 'Enabled') {
        Write-Log "$DisplayName já habilitado."
        return
    }

    if (-not (Test-IsAdmin)) {
        Write-Log "$DisplayName requer privilégios de administrador para habilitar. Pulando." 'WARN'
        return
    }

    Write-Log "Habilitando recurso do Windows: $DisplayName ($FeatureName)..."
    $exitCode = Invoke-NativeWithLog -Exe 'dism.exe' -Args @(
        '/online',
        '/Enable-Feature',
        "/FeatureName:$FeatureName",
        '/All',
        '/NoRestart'
    )
    if (($exitCode -ne 0) -and ($exitCode -ne 3010)) { throw "Falha ao habilitar recurso do Windows: $DisplayName (exit=$exitCode)." }
    Write-Log "$DisplayName habilitado. Pode ser necessário reiniciar o Windows." 'WARN'
}

function Ensure-WslUi {
    param([Parameter(Mandatory = $true)][string]$WingetPath)

    $id = 'OctasoftLtd.WSLUI'
    $name = 'WSL UI'
    if (Test-WingetPackageInstalled -WingetPath $WingetPath -Id $id) {
        Write-Log "$name já instalado (winget)."
        return
    }

    if (-not (Test-IsAdmin)) {
        Write-Log "$name requer privilégios de administrador (e dependências). Pulando instalação." 'WARN'
        return
    }

    Ensure-WindowsOptionalFeatureEnabled -FeatureName 'Microsoft-Windows-Subsystem-Linux' -DisplayName 'Microsoft-Windows-Subsystem-Linux (WSL)'
    Ensure-WingetPackage -WingetPath $WingetPath -Id 'Microsoft.EdgeWebView2Runtime' -DisplayName 'Microsoft Edge WebView2 Runtime'

    try {
        Ensure-WingetPackage -WingetPath $WingetPath -Id $id -DisplayName $name -PreferUserScope $false
    } catch {
        Write-Log ("Falha ao instalar $name via winget. Verifique WSL/WebView2 e privilégios. " + $_.Exception.Message) 'WARN'
    }
}

function Get-Winget {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function Ensure-Winget {
    $winget = Get-Winget
    if (-not $winget) { throw 'winget não encontrado. Instale o App Installer da Microsoft Store.' }
    $version = & $winget --version
    Write-Log "winget: $version"
    return $winget
}

function Ensure-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$DisplayName = $Id,
        [bool]$PreferUserScope = $true,
        [bool]$AllowFailureWhenNotAdmin = $false
    )
    $isInstalled = Test-WingetPackageInstalled -WingetPath $WingetPath -Id $Id

    if ($isInstalled) {
        Write-Log "$DisplayName já instalado (winget)."
        return
    }

    Write-Log "Instalando $DisplayName via winget..."
    $commonArgs = @(
        'install',
        '-e',
        '--id', $Id,
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity'
    )

    $exitCode = -1
    if ($PreferUserScope) {
        $exitCode = Invoke-NativeWithLog -Exe $WingetPath -Args (@($commonArgs) + @('--scope', 'user'))
        if ($exitCode -ne 0) {
            Write-Log "Falha ao instalar $DisplayName com --scope user (winget). Tentando novamente sem --scope..." 'WARN'
        }
    }
    if ($exitCode -ne 0) {
        $exitCode = Invoke-NativeWithLog -Exe $WingetPath -Args $commonArgs
    }
    if ($exitCode -ne 0) {
        if ($AllowFailureWhenNotAdmin -and (-not (Test-IsAdmin))) {
            Write-Log "$DisplayName falhou via winget sem privilégios de administrador (exit=$exitCode). Pulando." 'WARN'
            return
        }
        throw "Falha ao instalar $DisplayName via winget (exit=$exitCode)."
    }
    Refresh-SessionPath
    Write-Log "Instalação concluída: $DisplayName"
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath,
        [Parameter(Mandatory = $true)][string]$Id
    )
    try {
        $out = & $WingetPath list -e --id $Id 2>&1
        if (-not $out) { return $false }
        return (($out | Out-String) -match [regex]::Escape($Id))
    } catch {
        return $false
    }
}

function Ensure-Python {
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath
    )

    $pythonExe = Resolve-CommandPath -Name 'python'
    if ($pythonExe -and ($pythonExe -notmatch '\\Microsoft\\WindowsApps\\')) {
        $ver = ((& $pythonExe --version) 2>&1 | Select-Object -First 1)
        Write-Log "python já instalado: $ver ($pythonExe)"
        Ensure-PythonPathHealthy -PythonExe $pythonExe
        return
    }

    $pyLauncher = Resolve-CommandPath -Name 'py'
    if ($pyLauncher -and ($pyLauncher -notmatch '\\Microsoft\\WindowsApps\\')) {
        $ver = ((& $pyLauncher -3 --version) 2>&1 | Select-Object -First 1)
        Write-Log "Python já instalado (py launcher): $ver ($pyLauncher)"
        try {
            $out = (& $pyLauncher -3 -c 'import sys; print(sys.executable)' 2>&1) | Select-Object -First 1
            if ($out -and (Test-Path $out)) { Ensure-PythonPathHealthy -PythonExe $out }
        } catch {
        }
        return
    }

    Ensure-WingetPackage -WingetPath $WingetPath -Id 'Python.Python.3.13' -DisplayName 'Python 3.13'
    Refresh-SessionPath

    $pythonExe = Resolve-CommandPath -Name 'python'
    if (-not $pythonExe -or ($pythonExe -match '\\Microsoft\\WindowsApps\\')) {
        $roots = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
            (Join-Path $env:ProgramFiles 'Python'),
            $env:ProgramFiles
        ) | Where-Object { $_ -and (Test-Path $_) }

        $realPython = $null
        foreach ($root in $roots) {
            $dirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^Python3' } |
                Sort-Object Name -Descending
            foreach ($d in $dirs) {
                $candidate = Join-Path $d.FullName 'python.exe'
                if (Test-Path $candidate) { $realPython = $candidate; break }
            }
            if ($realPython) { break }
        }

        if ($realPython) {
            Ensure-PythonPathHealthy -PythonExe $realPython
            $pythonExe = Resolve-CommandPath -Name 'python'
        }
    }

    if (-not $pythonExe -or ($pythonExe -match '\\Microsoft\\WindowsApps\\')) { throw 'Python instalado via winget, mas o comando python não foi encontrado no PATH.' }
    $ver = ((& $pythonExe --version) 2>&1 | Select-Object -First 1)
    Write-Log "python instalado: $ver ($pythonExe)"
    Ensure-PythonPathHealthy -PythonExe $pythonExe
}

function Get-GitExe {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        Join-Path $env:ProgramFiles 'Git\cmd\git.exe',
        Join-Path $env:ProgramFiles 'Git\bin\git.exe',
        Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe',
        Join-Path ${env:ProgramFiles(x86)} 'Git\bin\git.exe'
    ) | Where-Object { $_ -and (Test-Path $_) }
    return $candidates | Select-Object -First 1
}

function Get-GitBashExe {
    $fromUser = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
    if ($fromUser -and (Test-Path $fromUser)) { return (Get-Item $fromUser).FullName }
    if ($env:CLAUDE_CODE_GIT_BASH_PATH -and (Test-Path $env:CLAUDE_CODE_GIT_BASH_PATH)) { return (Get-Item $env:CLAUDE_CODE_GIT_BASH_PATH).FullName }
    $candidates = @(
        Join-Path $env:ProgramFiles 'Git\bin\bash.exe',
        Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe',
        Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe',
        Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\bash.exe'
    ) | Where-Object { $_ -and (Test-Path $_) }
    return $candidates | Select-Object -First 1
}

function Ensure-GitAndBash {
    param([Parameter(Mandatory = $true)][string]$WingetPath)
    $git = Get-GitExe
    if (-not $git) {
        Ensure-WingetPackage -WingetPath $WingetPath -Id 'Git.Git' -DisplayName 'Git for Windows'
        $git = Get-GitExe
    }
    if (-not $git) { throw 'Falha ao localizar git.exe após a instalação.' }
    $gitVersion = & $git --version
    Write-Log "git: $gitVersion ($git)"

    $bash = Get-GitBashExe
    if (-not $bash) { throw 'bash.exe (Git Bash) não encontrado após a instalação do Git.' }
    Set-UserEnvVar -Name 'CLAUDE_CODE_GIT_BASH_PATH' -Value $bash
    Write-Log "bash: $bash"
    return @{ Git = $git; Bash = $bash }
}

function Get-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:ProgramFiles 'nodejs\node.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function Get-NpmCmd {
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function Get-NodeMajor {
    param([Parameter(Mandatory = $true)][string]$NodePath)
    $raw = & $NodePath -v
    if (-not $raw) { return 0 }
    $raw = $raw.Trim()
    if ($raw.StartsWith('v')) { $raw = $raw.Substring(1) }
    $major = 0
    [void][int]::TryParse(($raw.Split('.')[0]), [ref]$major)
    return $major
}

function Ensure-NodeAndNpm {
    param([Parameter(Mandatory = $true)][string]$WingetPath)
    $node = Get-NodeExe
    $needsInstall = $true
    if ($node) {
        $major = Get-NodeMajor -NodePath $node
        if ($major -ge 18) { $needsInstall = $false }
    }

    if ($needsInstall) {
        Ensure-WingetPackage -WingetPath $WingetPath -Id 'OpenJS.NodeJS.LTS' -DisplayName 'Node.js (LTS)'
        Refresh-SessionPath
        $node = Get-NodeExe
    }
    if (-not $node) { throw 'Falha ao localizar node.exe após a instalação.' }
    $nodeVersion = & $node -v
    Write-Log "node: $nodeVersion ($node)"

    $npmCmd = Get-NpmCmd
    if (-not $npmCmd) { throw 'Falha ao localizar npm.cmd após a instalação.' }
    $npmVersion = & $npmCmd --version
    Write-Log "npm: $npmVersion ($npmCmd)"

    $defaultNpmBin = Join-Path $env:APPDATA 'npm'
    $npmPrefix = $null
    try {
        $npmPrefix = (& $npmCmd prefix -g 2>$null | Select-Object -First 1)
        if ($npmPrefix) { $npmPrefix = $npmPrefix.Trim() }
    } catch {
        $npmPrefix = $null
    }

    $npmBin = $defaultNpmBin
    Ensure-PathUserContains -Dir $defaultNpmBin
    if ($npmPrefix -and (Test-Path $npmPrefix)) {
        Ensure-PathUserContains -Dir $npmPrefix
        $npmBin = $npmPrefix
    }

    return @{ Node = $node; NpmCmd = $npmCmd; NpmBin = $npmBin }
}

function Invoke-NpmWithLog {
    param(
        [Parameter(Mandatory = $true)][string]$NpmCmd,
        [Parameter(Mandatory = $true)][string[]]$Args
    )
    return (Invoke-NativeWithLog -Exe $NpmCmd -Args $Args)
}

function Invoke-NativeFirstLine {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Args = @()
    )

    $argsText = ''
    if ($Args -and $Args.Count -gt 0) { $argsText = ($Args -join ' ') }
    $cmdLine = ('"{0}" {1} 2>&1' -f ($Exe -replace '"', '""'), $argsText).Trim()
    $out = & $env:ComSpec /c $cmdLine
    return ($out | Select-Object -First 1)
}

function Ensure-NpmGlobalPackage {
    param(
        [Parameter(Mandatory = $true)][string]$NpmCmd,
        [Parameter(Mandatory = $true)][string]$Package,
        [string]$DisplayName = $Package,
        [string]$CheckName
    )
    if (-not $CheckName) {
        if ($Package.StartsWith('@')) {
            $CheckName = $Package
        } elseif ($Package -like '*@*') {
            $CheckName = $Package.Split('@')[0]
        } else {
            $CheckName = $Package
        }
    }
    $installed = $false
    try {
        $out = & $NpmCmd list -g --depth=0 2>$null
        if ($out -match [regex]::Escape($CheckName) + '@') { $installed = $true }
    } catch {
        $installed = $false
    }

    if ($installed) {
        Write-Log "$DisplayName já instalado via npm -g."
        return
    }

    Write-Log "Instalando $DisplayName via npm -g..."
    $exitCode = Invoke-NpmWithLog -NpmCmd $NpmCmd -Args @('install', '-g', $Package)
    if ($exitCode -ne 0) { throw "Falha ao instalar $DisplayName via npm (exit=$exitCode)." }
    Write-Log "Instalação concluída: $DisplayName"
}

function Ensure-ClaudeCode {
    param([Parameter(Mandatory = $true)][string]$WingetPath)

    $claudeExe = Resolve-CommandPath -Name 'claude'
    if ($claudeExe) {
        $ver = ((& $claudeExe --version) 2>&1 | Select-Object -First 1)
        Write-Log "claude já instalado: $ver ($claudeExe)"
        return
    }

    Ensure-WingetPackage -WingetPath $WingetPath -Id 'Anthropic.ClaudeCode' -DisplayName 'Claude Code (Anthropic)'
    Refresh-SessionPath

    $claudeExe = Resolve-CommandPath -Name 'claude'
    if (-not $claudeExe) { throw 'Claude Code instalado (winget), mas o comando claude não foi encontrado no PATH.' }
    $ver = ((& $claudeExe --version) 2>&1 | Select-Object -First 1)
    Write-Log "claude instalado: $ver ($claudeExe)"
}

function Ensure-CodexInstaller {
    param([Parameter(Mandatory = $true)][string]$WingetPath)

    $id = 'OpenAI.Codex'
    $codexCmdDefault = Join-Path (Join-Path $env:APPDATA 'npm') 'codex.cmd'
    if (Test-Path $codexCmdDefault) {
        Write-Log "Codex CLI já presente via npm ($codexCmdDefault). Pulando instalação via winget ($id)."
        return
    }
    $npmCmd = Get-NpmCmd
    if ($npmCmd) {
        $npmPrefix = $null
        try {
            $npmPrefix = (& $npmCmd prefix -g 2>$null | Select-Object -First 1)
            if ($npmPrefix) { $npmPrefix = $npmPrefix.Trim() }
        } catch {
            $npmPrefix = $null
        }
        if ($npmPrefix) {
            $codexCmdFromPrefix = Join-Path $npmPrefix 'codex.cmd'
            if (Test-Path $codexCmdFromPrefix) {
                Write-Log "Codex CLI já presente via npm ($codexCmdFromPrefix). Pulando instalação via winget ($id)."
                return
            }
        }
    }

    if (Test-WingetPackageInstalled -WingetPath $WingetPath -Id $id) {
        Write-Log "Codex Installer ($id) já instalado (winget)."
        return
    }

    try {
        Ensure-WingetPackage -WingetPath $WingetPath -Id $id -DisplayName "Codex Installer ($id)" -AllowFailureWhenNotAdmin $true
    } catch {
        Write-Log ("Falha ao instalar Codex Installer via winget. Continuando. " + $_.Exception.Message) 'WARN'
    }
}

function Ensure-Uv {
    $uvExe = Resolve-CommandPath -Name 'uv'
    if ($uvExe) {
        $ver = Invoke-NativeFirstLine -Exe $uvExe -Args @('--version')
        Write-Log "uv já instalado: $ver ($uvExe)"
        return $uvExe
    }

    $pythonExe = Resolve-CommandPath -Name 'python'
    if (-not $pythonExe) { throw 'uv é necessário, mas o comando python não foi encontrado para instalar uv via pip.' }

    Write-Log 'Instalando uv via pip...'
    $exitCode = Invoke-NativeWithLog -Exe $pythonExe -Args @('-m', 'pip', 'install', '-U', '--upgrade-strategy', 'only-if-needed', 'uv')
    if ($exitCode -ne 0) { throw "Falha ao instalar uv via pip (exit=$exitCode)." }

    Refresh-SessionPath
    $uvExe = Resolve-CommandPath -Name 'uv'
    if (-not $uvExe) { throw 'Instalação do uv concluída, mas o comando uv não foi encontrado no PATH.' }

    $ver = Invoke-NativeFirstLine -Exe $uvExe -Args @('--version')
    Write-Log "uv instalado: $ver ($uvExe)"
    return $uvExe
}

function Ensure-UvToolPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string]$DisplayName = $Package,
        [string[]]$VersionArgs = @('--version')
    )

    $exe = Resolve-CommandPath -Name $CommandName
    if ($exe) {
        $ver = Invoke-NativeFirstLine -Exe $exe -Args $VersionArgs
        Write-Log "$DisplayName já instalado: $ver ($exe)"
        return
    }

    $uvExe = Ensure-Uv
    $localBin = Join-Path $env:USERPROFILE '.local\bin'
    $null = New-Item -Path $localBin -ItemType Directory -Force
    $env:UV_TOOL_BIN_DIR = $localBin

    Write-Log "Instalando $DisplayName ($Package) via uv tool..."
    $exitCode = Invoke-NativeWithLog -Exe $uvExe -Args @('tool', 'install', '--reinstall', $Package)
    if ($exitCode -ne 0) { throw "Falha ao instalar $DisplayName via uv tool (exit=$exitCode)." }

    Ensure-PathUserContains -Dir $localBin
    Refresh-SessionPath

    $exe = Resolve-CommandPath -Name $CommandName
    if (-not $exe) { throw "Instalação do $DisplayName concluída, mas o comando $CommandName não foi encontrado no PATH." }

    $ver = Invoke-NativeFirstLine -Exe $exe -Args $VersionArgs
    Write-Log "$DisplayName instalado: $ver ($exe)"
}

function Ensure-Aider {
    Ensure-UvToolPackage -Package 'aider-chat' -CommandName 'aider' -DisplayName 'aider (aider-chat)' -VersionArgs @('--version')
}

function Ensure-Goose {
    param([Parameter(Mandatory = $true)][string]$BashPath)

    $gooseExe = Resolve-CommandPath -Name 'goose'
    if ($gooseExe) {
        $ver = Invoke-NativeFirstLine -Exe $gooseExe -Args @('--version')
        Write-Log "goose já instalado: $ver ($gooseExe)"
        return
    }

    $localBin = Join-Path $env:USERPROFILE '.local\bin'
    $null = New-Item -Path $localBin -ItemType Directory -Force
    Ensure-PathUserContains -Dir $localBin
    Refresh-SessionPath

    $destExe = Join-Path $localBin 'goose.exe'
    if (-not (Test-Path $destExe)) {
        $url = 'https://github.com/aaif-goose/goose/releases/download/stable/goose-x86_64-pc-windows-msvc.zip'
        $zipPath = Join-Path $env:TEMP ("goose_{0}.zip" -f ([Guid]::NewGuid().ToString('N')))
        $extractDir = Join-Path $env:TEMP ("goose_extract_{0}" -f ([Guid]::NewGuid().ToString('N')))
        try {
            Write-Log "Baixando goose (stable): $url"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zipPath | Out-Null
            Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
            $found = Get-ChildItem -Path $extractDir -Recurse -File -Filter 'goose.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $found) { throw "Não encontrei goose.exe dentro do zip: $url" }
            Copy-Item -LiteralPath $found.FullName -Destination $destExe -Force
        } finally {
            if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    Refresh-SessionPath

    $gooseExe = Resolve-CommandPath -Name 'goose'
    if (-not $gooseExe) { throw 'Instalação do goose concluída, mas o comando goose não foi encontrado no PATH.' }

    $ver = Invoke-NativeFirstLine -Exe $gooseExe -Args @('--version')
    Write-Log "goose instalado: $ver ($gooseExe)"
}

function Ensure-OpenCode {
    param([Parameter(Mandatory = $true)][string]$BashPath)
    $userProfileDir = $env:USERPROFILE
    $binDir = Join-Path $userProfileDir '.opencode\bin'
    $exe = Join-Path $binDir 'opencode.exe'

    if (Test-Path $exe) {
        $ver = & $exe --version
        Write-Log "opencode já instalado: $ver ($exe)"
    } else {
        Write-Log 'Instalando opencode via script oficial...'
        $exitCode = Invoke-NativeWithLog -Exe $BashPath -Args @('-lc', 'set -e; curl -fsSL https://opencode.ai/install | bash')
        if ($exitCode -ne 0) { throw "Falha ao instalar opencode via script oficial (exit=$exitCode)." }
        if (-not (Test-Path $exe)) { throw "Instalação do opencode concluída, mas não encontrei: $exe" }
        $ver = & $exe --version
        Write-Log "opencode instalado: $ver ($exe)"
    }

    Ensure-PathUserContains -Dir $binDir
}

function Ensure-OpenClaw {
    param([Parameter(Mandatory = $true)][string]$NpmCmd)

    $npmPrefix = & $NpmCmd prefix -g
    if (-not $npmPrefix) { throw 'Não foi possível determinar o prefixo global do npm.' }

    $openclawCmd = Join-Path $npmPrefix 'openclaw.cmd'
    $openclawModuleDir = Join-Path (Join-Path $npmPrefix 'node_modules') 'openclaw'

    if (Test-Path $openclawCmd) {
        $ver = Invoke-NativeFirstLine -Exe $openclawCmd -Args @('--version')
        Write-Log "openclaw já instalado: $ver ($openclawCmd)"
        return
    }

    if (Test-Path $openclawModuleDir) {
        Write-Log "Encontrada instalação parcial do OpenClaw, removendo: $openclawModuleDir" 'WARN'
        for ($i = 0; $i -lt 5; $i++) {
            try {
                Remove-Item -LiteralPath $openclawModuleDir -Recurse -Force -ErrorAction Stop
                break
            } catch {
                Start-Sleep -Milliseconds 500
            }
        }
    }

    Write-Log 'Instalando OpenClaw (openclaw) via npm -g...'
    $exitCode = Invoke-NpmWithLog -NpmCmd $NpmCmd -Args @('install', '-g', 'openclaw@latest')
    if ($exitCode -ne 0) {
        Write-Log 'Falha ao instalar OpenClaw. Tentando limpeza e retry...' 'WARN'

        foreach ($p in @($openclawModuleDir, $openclawCmd, (Join-Path $npmPrefix 'openclaw.ps1'), (Join-Path $npmPrefix 'openclaw'))) {
            for ($i = 0; $i -lt 3; $i++) {
                try {
                    if (Test-Path $p) {
                        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                    }
                    break
                } catch {
                    Start-Sleep -Milliseconds 300
                }
            }
        }

        $exitCode2 = Invoke-NpmWithLog -NpmCmd $NpmCmd -Args @('install', '-g', 'openclaw@latest', '--force')
        if ($exitCode2 -ne 0) { throw "Falha ao instalar OpenClaw via npm (mesmo após retry) (exit=$exitCode2)." }
    }

    if (-not (Test-Path $openclawCmd)) { throw "Instalação do OpenClaw concluída, mas não encontrei: $openclawCmd" }
    $ver = Invoke-NativeFirstLine -Exe $openclawCmd -Args @('--version')
    Write-Log "openclaw instalado: $ver ($openclawCmd)"
}

function Ensure-RepoClone {
    param(
        [Parameter(Mandatory = $true)][string]$GitExe,
        [Parameter(Mandatory = $true)][string]$RepoUrl,
        [Parameter(Mandatory = $true)][string]$TargetDir
    )
    if (Test-Path $TargetDir) {
        Write-Log "Diretório já existe, pulando clone: $TargetDir"
        return
    }
    Write-Log "Clonando $RepoUrl em $TargetDir"
    $exitCode = Invoke-NativeWithLog -Exe $GitExe -Args @('clone', $RepoUrl, $TargetDir)
    if ($exitCode -ne 0) { throw "Falha ao clonar repositório (exit=$exitCode): $RepoUrl" }
    Write-Log "Clone concluído: $TargetDir"
}

function Resolve-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ─────────────────────────────────────────────────────────────
# Dual Boot Management Module
# ─────────────────────────────────────────────────────────────

function Get-BootstrapFastStartupStatus {
    $result = @{ Enabled = $false; Safe = $true; RegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; Value = $null }
    try {
        $val = Get-ItemProperty -Path $result.RegistryPath -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue
        if ($null -ne $val -and $val.HiberbootEnabled -eq 1) {
            $result.Enabled = $true
            $result.Safe    = $false
            $result.Value   = 1
        } else {
            $result.Value = if ($null -ne $val) { $val.HiberbootEnabled } else { $null }
        }
    } catch { }
    return $result
}

function Get-BootstrapBitLockerStatus {
    $result = @{ CEnabled = $false; StatusText = 'unknown' }
    try {
        $output = & manage-bde -status C: 2>$null
        if ($output) {
            $statusLine = $output | Where-Object { $_ -match 'Protection Status|Status de Prote' } | Select-Object -First 1
            if ($statusLine -match '(On|Ativad)') {
                $result.CEnabled   = $true
                $result.StatusText = 'enabled'
            } else {
                $result.StatusText = 'disabled'
            }
        }
    } catch {
        $result.StatusText = 'error'
    }
    return $result
}

function Get-BootstrapLinuxPartitions {
    $linuxPartitions = @()
    try {
        $partitions = Get-Partition -ErrorAction SilentlyContinue
        foreach ($p in $partitions) {
            $vol = $null
            try { $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue } catch { }
            $fsType = if ($vol) { [string]$vol.FileSystemType } else { '' }
            $isLinux = ($fsType -eq '' -or $fsType -eq 'Unknown' -or $fsType -eq 'RAW') -and
                       ($p.Type -notin @('System', 'Reserved', 'Recovery', 'IU', 'Basic')) -and
                       ($p.Size -gt 1GB)
            if ($isLinux) {
                $linuxPartitions += @{
                    DiskNumber      = $p.DiskNumber
                    PartitionNumber = $p.PartitionNumber
                    SizeGB          = [math]::Round($p.Size / 1GB, 1)
                    Type            = [string]$p.Type
                    FileSystem      = if ($fsType) { $fsType } else { 'Unknown' }
                    GptType         = if ($p.GptType) { [string]$p.GptType } else { '' }
                }
            }
        }
    } catch { }
    return @($linuxPartitions)
}

function Get-BootstrapEfiEntries {
    if (-not (Test-IsAdmin)) { return $null }
    $entries = @()
    try {
        $raw = & bcdedit /enum firmware 2>$null
        if (-not $raw) { return @() }
        $currentEntry = $null
        foreach ($line in $raw) {
            if ($line -match '^[-]+$') { continue }
            if ($line -match '^\s*$') {
                if ($currentEntry) { $entries += $currentEntry }
                $currentEntry = $null
                continue
            }
            if ($line -match '^(?:Firmware Boot Manager|Gerenciador de Inicializa)') {
                $currentEntry = @{ Type = 'bootmgr'; Id = ''; Description = ''; Path = '' }
                continue
            }
            if ($line -match '^(?:Firmware Application|Aplicativo de Firmware)') {
                $currentEntry = @{ Type = 'entry'; Id = ''; Description = ''; Path = '' }
                continue
            }
            if ($null -ne $currentEntry) {
                if ($line -match '(?:identifier|identificador)\s+(.+)') { $currentEntry.Id = ($Matches[1]).Trim() }
                if ($line -match '(?:description|descri)\s+(.+)')       { $currentEntry.Description = ($Matches[1]).Trim() }
                if ($line -match '(?:path|caminho)\s+(.+)')             { $currentEntry.Path = ($Matches[1]).Trim() }
            }
        }
        if ($currentEntry) { $entries += $currentEntry }
    } catch { }
    return @($entries)
}

function Get-BootstrapGrubPresence {
    if (-not (Test-IsAdmin)) { return @{ Detected = $null; Path = ''; Confidence = 'unknown' } }
    $result = @{ Detected = $false; Path = ''; Confidence = 'none' }
    $efiEntries = Get-BootstrapEfiEntries
    foreach ($entry in $efiEntries) {
        if ($entry.Type -ne 'entry') { continue }
        $p = [string]$entry.Path
        $d = [string]$entry.Description
        if ($p -match 'grubx64\.efi|shimx64\.efi' -or $d -match 'ubuntu|fedora|bazzite|steamos|linux|grub|refind|Pop!_OS|manjaro|arch|debian|opensuse|nixos') {
            $result.Detected   = $true
            $result.Path       = $p
            $result.Confidence = 'high'
            $result.EntryId    = $entry.Id
            $result.EntryDesc  = $d
            break
        }
    }
    if (-not $result.Detected) {
        $linuxParts = Get-BootstrapLinuxPartitions
        if ($linuxParts.Count -gt 0) {
            $result.Detected   = $true
            $result.Confidence = 'medium'
        }
    }
    return $result
}

function Test-BootstrapIsDualBoot {
    $grub = Get-BootstrapGrubPresence
    if ($grub.Detected -eq $true) { return $true }
    $linuxParts = Get-BootstrapLinuxPartitions
    return ($linuxParts.Count -gt 0)
}

function Get-BootstrapDualBootInfo {
    $isAdmin       = Test-IsAdmin
    $fastStartup   = Get-BootstrapFastStartupStatus
    $bitlocker     = Get-BootstrapBitLockerStatus
    $linuxParts    = Get-BootstrapLinuxPartitions
    $grub          = Get-BootstrapGrubPresence
    $efiEntries    = if ($isAdmin) { Get-BootstrapEfiEntries } else { $null }
    $isDualBoot    = ($grub.Detected -eq $true) -or ($linuxParts.Count -gt 0)
    $confidence    = if ($grub.Confidence -eq 'high') { 'high' } elseif ($linuxParts.Count -gt 0) { 'medium' } else { 'none' }
    $detectedOS    = @('Windows')
    if ($grub.EntryDesc) { $detectedOS += $grub.EntryDesc }
    elseif ($linuxParts.Count -gt 0) { $detectedOS += 'Linux (unknown distro)' }

    $warnings = New-Object System.Collections.Generic.List[string]
    if ($fastStartup.Enabled) {
        $warnings.Add('Fast Startup esta habilitado. Isso pode corromper particoes Linux ou impedir montagem de volumes NTFS compartilhados.')
    }
    if ($bitlocker.CEnabled) {
        $warnings.Add('BitLocker esta ativo em C:. Alteracoes no EFI podem disparar recuperacao do BitLocker.')
    }
    if (-not $isAdmin) {
        $warnings.Add('Executando sem privilegios de administrador. Algumas informacoes de EFI e disco podem estar incompletas.')
    }

    return @{
        IsDualBoot      = $isDualBoot
        Confidence      = $confidence
        DetectedOS      = @($detectedOS)
        GrubDetected    = [bool]$grub.Detected
        GrubEfiPath     = [string]$grub.Path
        GrubEntryId     = if ($grub.EntryId) { [string]$grub.EntryId } else { '' }
        GrubEntryDesc   = if ($grub.EntryDesc) { [string]$grub.EntryDesc } else { '' }
        LinuxPartitions = @($linuxParts)
        EfiEntries      = $efiEntries
        FastStartup     = $fastStartup
        BitLocker       = $bitlocker
        IsAdmin         = $isAdmin
        Warnings        = @($warnings.ToArray())
    }
}

# --- Guardrails ---

function Test-BootstrapSafePartition {
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [Parameter(Mandatory = $true)][int]$PartitionNumber
    )
    try {
        $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction Stop
    } catch {
        return $false
    }
    if ($p.Type -in @('System', 'Reserved', 'Recovery')) { return $false }
    $vol = $null
    try { $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue } catch { }
    $fs = if ($vol) { [string]$vol.FileSystemType } else { '' }
    if ($fs -eq '' -or $fs -eq 'Unknown' -or $fs -eq 'RAW') { return $false }
    return $true
}

function Assert-BootstrapDiskSafety {
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [Parameter(Mandatory = $true)][int]$PartitionNumber,
        [string]$OperationName = 'disk operation'
    )
    if (-not (Test-BootstrapSafePartition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber)) {
        throw "BLOCKED: $OperationName on Disk $DiskNumber Partition $PartitionNumber is not allowed. The partition is EFI System, Recovery, or has an unrecognized (possibly Linux) filesystem. This guard prevents accidental destruction of dual-boot partitions."
    }
}

function Test-BootstrapSafeEfiOperation {
    if (-not (Test-IsAdmin)) { return $false }
    try {
        $entries = Get-BootstrapEfiEntries
        if ($null -eq $entries -or $entries.Count -eq 0) { return $false }
        $hasBootMgr = ($entries | Where-Object { $_.Type -eq 'bootmgr' }).Count -gt 0
        return $hasBootMgr
    } catch { return $false }
}

# --- Prerequisites ---

function Test-BootstrapDualBootPrerequisites {
    $issues = @()
    $fastStartup = Get-BootstrapFastStartupStatus
    if ($fastStartup.Enabled) {
        $issues += @{
            Id          = 'fast-startup'
            Severity    = 'critical'
            Title       = 'Fast Startup habilitado'
            Description = 'O Fast Startup faz o Windows hibernar em vez de desligar, o que pode corromper particoes compartilhadas e impedir o Linux de montar volumes NTFS.'
            CanAutoFix  = $true
        }
    }
    $bitlocker = Get-BootstrapBitLockerStatus
    if ($bitlocker.CEnabled) {
        $issues += @{
            Id          = 'bitlocker'
            Severity    = 'warning'
            Title       = 'BitLocker ativo em C:'
            Description = 'BitLocker pode disparar a tela de recuperacao se o bootloader EFI for alterado. Considere suspender o BitLocker antes de modificar entradas de boot.'
            CanAutoFix  = $false
        }
    }
    return @($issues)
}

function Repair-BootstrapFastStartup {
    if (-not (Test-IsAdmin)) {
        throw 'Repair-BootstrapFastStartup requer privilegios de administrador.'
    }
    $status = Get-BootstrapFastStartupStatus
    if (-not $status.Enabled) {
        Write-Log 'Fast Startup ja esta desabilitado.'
        return @{ Changed = $false; PreviousValue = $status.Value }
    }
    $regPath = $status.RegistryPath
    $previousValue = $status.Value
    Set-ItemProperty -Path $regPath -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force
    Write-Log "Fast Startup desabilitado (HiberbootEnabled: $previousValue -> 0)."
    return @{ Changed = $true; PreviousValue = $previousValue }
}

function Get-BootstrapDualBootRecommendations {
    param([AllowNull()]$DualBootInfo)
    if ($null -eq $DualBootInfo) { $DualBootInfo = Get-BootstrapDualBootInfo }
    $recs = New-Object System.Collections.Generic.List[string]
    if (-not $DualBootInfo.IsDualBoot) {
        $recs.Add('Nenhum dual boot detectado. Nenhuma acao necessaria.')
        return @($recs.ToArray())
    }
    if ($DualBootInfo.FastStartup.Enabled) {
        $recs.Add('[CRITICO] Desabilitar Fast Startup: evita corrupcao de particiones Linux.')
    }
    if ($DualBootInfo.BitLocker.CEnabled) {
        $recs.Add('[ATENCAO] BitLocker ativo: suspender antes de modificar bootloader.')
    }
    if ($DualBootInfo.GrubDetected) {
        $recs.Add('[INFO] GRUB detectado: ' + $DualBootInfo.GrubEfiPath)
    }
    if ($DualBootInfo.LinuxPartitions.Count -gt 0) {
        $recs.Add("[INFO] $($DualBootInfo.LinuxPartitions.Count) particao(oes) Linux detectada(s).")
    }
    $recs.Add('[DICA] Use o menu UEFI da BIOS (F12/F2/Del) como alternativa segura para trocar de SO.')
    return @($recs.ToArray())
}

# --- Reboot Switch ---

function Get-BootstrapAlternateBootEntries {
    if (-not (Test-IsAdmin)) { return @() }
    $entries = Get-BootstrapEfiEntries
    $alternates = @()
    foreach ($entry in $entries) {
        if ($entry.Type -ne 'entry') { continue }
        $d = [string]$entry.Description
        $p = [string]$entry.Path
        $isWindows = ($d -match 'Windows Boot Manager' -or $p -match 'bootmgfw\.efi')
        if (-not $isWindows -and $entry.Id) {
            $alternates += @{
                Id          = $entry.Id
                Description = $d
                Path        = $p
            }
        }
    }
    return @($alternates)
}

function Set-BootstrapOneTimeBootTarget {
    param(
        [Parameter(Mandatory = $true)][string]$EntryGuid,
        [switch]$CreateBackup
    )
    if (-not (Test-IsAdmin)) {
        throw 'Set-BootstrapOneTimeBootTarget requer privilegios de administrador.'
    }
    if (-not (Test-BootstrapSafeEfiOperation)) {
        throw 'Nao foi possivel validar as entradas EFI. Operacao cancelada por seguranca.'
    }
    if ($CreateBackup) {
        $backupDir = Join-Path (Get-BootstrapDataRoot) 'bcd-backups'
        if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
        $backupPath = Join-Path $backupDir ("bcd_backup_{0}.bak" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $exitCode = 0
        try {
            $output = & bcdedit /export $backupPath 2>&1
            if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
        } catch { $exitCode = 1 }
        if ($exitCode -ne 0) {
            Write-Log "[WARN] Falha ao criar backup do BCD: $backupPath"
        } else {
            Write-Log "BCD backup criado: $backupPath"
        }
    }
    $output = & bcdedit /set '{fwbootmgr}' bootsequence $EntryGuid 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao definir bootsequence: $output"
    }
    Write-Log "Bootsequence definido para: $EntryGuid (proximo boot apenas)."
    return @{ Success = $true; TargetGuid = $EntryGuid }
}

function Invoke-BootstrapRebootToLinux {
    param(
        [string]$PreferredEntryGuid,
        [switch]$Force
    )
    if (-not (Test-IsAdmin)) {
        throw 'Invoke-BootstrapRebootToLinux requer privilegios de administrador.'
    }
    $alternates = Get-BootstrapAlternateBootEntries
    if ($alternates.Count -eq 0) {
        throw 'Nenhuma entrada de boot alternativa (Linux/SteamOS) encontrada no firmware.'
    }
    $target = $null
    if ($PreferredEntryGuid) {
        $target = $alternates | Where-Object { $_.Id -eq $PreferredEntryGuid } | Select-Object -First 1
    }
    if (-not $target) {
        $target = $alternates[0]
    }
    Write-Log "Preparando boot em: $($target.Description) ($($target.Id))"
    Set-BootstrapOneTimeBootTarget -EntryGuid $target.Id -CreateBackup
    if (-not $Force) {
        Write-Log 'Bootsequence definido com sucesso. Reinicie manualmente quando estiver pronto.'
        return @{ Success = $true; Target = $target; Rebooted = $false }
    }
    Write-Log 'Reiniciando em 3 segundos...'
    & shutdown /r /t 3
    return @{ Success = $true; Target = $target; Rebooted = $true }
}

function Get-BootstrapPhantomBootEntries {
    if (-not (Test-IsAdmin)) { return @() }
    
    $phantoms = @()
    $displayOrderStr = & bcdedit /enum '{bootmgr}' 2>$null | Select-String '^displayorder'
    if (-not $displayOrderStr) { return @() }
    
    $guids = [regex]::Matches($displayOrderStr, '\{[a-f0-9\-]+\}') | ForEach-Object { $_.Value }
    
    foreach ($g in $guids) {
        if ($g -eq '{current}') { continue } # ignora a entrada atual em execucao ativa
        $entryLines = & bcdedit /enum $g 2>$null
        $isPhantom = $false
        $desc = ''
        foreach ($line in $entryLines) {
            if ($line -match '^description\s+(.*)') { $desc = $matches[1].Trim() }
            if ($line -match '^device\s+unknown' -or $line -match '^osdevice\s+unknown') {
                $isPhantom = $true
            }
        }
        if ($isPhantom) {
            $phantoms += @{ Id = $g; Description = $desc }
        }
    }
    return $phantoms
}

function Repair-BootstrapPhantomEntries {
    if (-not (Test-IsAdmin)) { throw 'Repair-BootstrapPhantomEntries requer privilegios de administrador.' }
    
    $phantoms = Get-BootstrapPhantomBootEntries
    if ($phantoms.Count -eq 0) { 
        return @{ Success = $true; Removed = 0; Message = 'Nenhuma entrada inativa encontrada.' } 
    }
    
    # Criar backup do BCD
    $backupDir = Join-Path (Get-BootstrapDataRoot) 'bcd-backups'
    if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
    $backupPath = Join-Path $backupDir ("bcd_backup_cleanup_{0}.bak" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    & bcdedit /export $backupPath 2>&1 | Out-Null
    Write-Log "Backup BCD concluido em: $backupPath antes da limpeza."

    $removedCount = 0
    foreach ($p in $phantoms) {
        Write-Log "Removendo phantom BCD entry: $($p.Description) ($($p.Id))"
        & bcdedit /delete $($p.Id) /cleanup 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $removedCount++ }
    }
    
    # Se sobrar so 1 no displayorder (e for o current), removemos o timeout para single-OS boot rapido
    $displayOrderStr = & bcdedit /enum '{bootmgr}' 2>$null | Select-String '^displayorder'
    if ($displayOrderStr) {
        $remainingGuids = [regex]::Matches($displayOrderStr, '\{[a-f0-9\-]+\}') | ForEach-Object { $_.Value }
        if ($remainingGuids.Count -eq 1 -and $remainingGuids[0] -eq '{current}') {
            & bcdedit /timeout 0 2>&1 | Out-Null
            Write-Log "Otimizacao: Timeout definido para 0 pois sobrou apenas a instalacao corrente."
        }
    }
    
    return @{ Success = $true; Removed = $removedCount; Backup = $backupPath }
}

# ─────────────────────────────────────────────────────────────
# End of Dual Boot Module
# ─────────────────────────────────────────────────────────────

function New-BootstrapComponentDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [string[]]$DependsOn = @(),
        [bool]$Optional = $true,
        [Parameter(Mandatory = $true)][string]$Kind,
        [hashtable]$Data = @{}
    )

    $definition = [ordered]@{
        Name = $Name
        Description = $Description
        DependsOn = @($DependsOn)
        Optional = $Optional
        Kind = $Kind
    }

    foreach ($key in $Data.Keys) {
        $definition[$key] = $Data[$key]
    }

    return [pscustomobject]$definition
}

function New-BootstrapProfileDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [string[]]$Items = @()
    )

    return [pscustomobject]@{
        Name = $Name
        Description = $Description
        Items = @($Items)
    }
}

function Normalize-BootstrapNames {
    param([string[]]$Names)

    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        foreach ($item in ($name -split ',')) {
            $trimmed = $item.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $normalized.Add($trimmed.ToLowerInvariant())
            }
        }
    }

    return @($normalized.ToArray())
}

function ConvertTo-BootstrapHashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-BootstrapHashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += @(ConvertTo-BootstrapHashtable -InputObject $item)
        }
        return @($items)
    }

    if ($InputObject -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-BootstrapHashtable -InputObject $property.Value
        }
        return $result
    }

    return $InputObject
}

function Merge-BootstrapData {
    param(
        [AllowNull()][Parameter(Mandatory = $true)]$Defaults,
        $Current
    )

    $normalizedDefaults = ConvertTo-BootstrapHashtable -InputObject $Defaults
    $normalizedCurrent = ConvertTo-BootstrapHashtable -InputObject $Current

    if ($normalizedDefaults -is [hashtable]) {
        $result = @{}
        foreach ($key in $normalizedDefaults.Keys) {
            if (($normalizedCurrent -is [hashtable]) -and $normalizedCurrent.ContainsKey($key)) {
                $result[$key] = Merge-BootstrapData -Defaults $normalizedDefaults[$key] -Current $normalizedCurrent[$key]
            } else {
                $result[$key] = $normalizedDefaults[$key]
            }
        }

        if ($normalizedCurrent -is [hashtable]) {
            foreach ($key in $normalizedCurrent.Keys) {
                if (-not $result.ContainsKey($key)) {
                    $result[$key] = $normalizedCurrent[$key]
                }
            }
        }

        return $result
    }

    if (($normalizedDefaults -is [System.Array]) -and ($normalizedDefaults.Count -gt 0)) {
        if (($normalizedCurrent -is [System.Array]) -and ($normalizedCurrent.Count -gt 0)) {
            return @($normalizedCurrent)
        }
        return @($normalizedDefaults)
    }

    if ($null -ne $normalizedCurrent) {
        if ($normalizedCurrent -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($normalizedCurrent)) {
                return $normalizedCurrent
            }
        } else {
            return $normalizedCurrent
        }
    }

    return $normalizedDefaults
}

function ConvertTo-BootstrapObjectGraph {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-BootstrapObjectGraph -InputObject $InputObject[$key]
        }
        return [pscustomobject]$result
    }

    if ($InputObject -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-BootstrapObjectGraph -InputObject $property.Value
        }
        return [pscustomobject]$result
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += @(ConvertTo-BootstrapObjectGraph -InputObject $item)
        }
        return @($items)
    }

    return $InputObject
}

function Normalize-BootstrapObjectArray {
    param($Value)

    if ($null -eq $Value) { return @() }

    if (($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject])) {
        $propertyCount = if ($Value -is [pscustomobject]) { @($Value.PSObject.Properties).Count } else { @($Value.Keys).Count }
        if ($propertyCount -eq 0) { return @() }
        return @((ConvertTo-BootstrapHashtable -InputObject $Value))
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += @(ConvertTo-BootstrapHashtable -InputObject $item)
        }
        return @($items)
    }

    return @($Value)
}

function Get-BootstrapHostHealthModes {
    return @('off', 'conservador', 'equilibrado', 'agressivo')
}

function Show-BootstrapHostHealthModes {
    foreach ($mode in (Get-BootstrapHostHealthModes)) {
        Write-Output $mode
    }
}

function Normalize-BootstrapHostHealthMode {
    param([AllowNull()][string]$Mode)

    if ([string]::IsNullOrWhiteSpace($Mode)) { return $null }
    $normalized = $Mode.Trim().ToLowerInvariant()
    if ((Get-BootstrapHostHealthModes) -notcontains $normalized) {
        throw "Modo de HostHealth desconhecido: $Mode"
    }
    return $normalized
}

function Get-BootstrapDefaultHostHealthMode {
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)]$Resolution
    )

    $selectedProfiles = @($Selection.Profiles)
    $selectedComponents = @($Selection.Components)
    $expandedProfiles = @($Resolution.ExpandedProfiles)

    if (($selectedComponents.Count -eq 0) -and ($selectedProfiles.Count -eq 1) -and ($selectedProfiles[0] -eq 'legacy') -and ($expandedProfiles.Count -eq 1) -and ($expandedProfiles[0] -eq 'legacy')) {
        return 'off'
    }

    return 'conservador'
}

function Get-BootstrapHostHealthRoot {
    return (Join-Path (Join-Path (Get-BootstrapDataRoot) 'host-health') ('{0:yyyyMMdd_HHmmss}' -f $script:StartTime))
}

function Get-BootstrapHostHealthPolicy {
    param([Parameter(Mandatory = $true)][string]$Mode)

    $normalizedMode = Normalize-BootstrapHostHealthMode -Mode $Mode
    $appxRemove = @()
    if ($normalizedMode -eq 'equilibrado') {
        $appxRemove = @(
            'Microsoft.GetHelp',
            'Microsoft.WindowsFeedbackHub',
            'Microsoft.Todos',
            'Microsoft.OutlookForWindows',
            'MSTeams',
            'Microsoft.YourPhone',
            'Microsoft.ZuneMusic',
            'Microsoft.WindowsAlarms',
            'Microsoft.Windows.DevHome'
        )
    } elseif ($normalizedMode -eq 'agressivo') {
        $appxRemove = @(
            'Microsoft.GetHelp',
            'Microsoft.WindowsFeedbackHub',
            'Microsoft.Todos',
            'Microsoft.OutlookForWindows',
            'MSTeams',
            'Microsoft.YourPhone',
            'Microsoft.ZuneMusic',
            'Microsoft.WindowsAlarms',
            'Microsoft.Windows.DevHome',
            'Microsoft.BingSearch',
            'Microsoft.MicrosoftPCManager'
        )
    }

    $scheduledTasks = @()
    if ($normalizedMode -in @('equilibrado', 'agressivo')) {
        $scheduledTasks = @(
            [ordered]@{ TaskPath = '\Microsoft\Windows\Maps\'; TaskName = 'MapsUpdateTask' },
            [ordered]@{ TaskPath = '\Microsoft\Windows\Windows Media Sharing\'; TaskName = 'UpdateLibrary' }
        )
    }

    $serviceAdjustments = @()
    if ($normalizedMode -eq 'agressivo') {
        $serviceAdjustments = @(
            [ordered]@{ Name = 'MapsBroker'; StartType = 'Disabled' }
        )
    }

    return [pscustomobject]@{
        Mode = $normalizedMode
        Cleanup = @(
            '%TEMP%',
            '%LOCALAPPDATA%\Temp',
            'C:\Windows\Temp',
            'Bootstrap temp/log residues',
            'DISM /Online /Cleanup-Image /StartComponentCleanup (admin)',
            'C:\Windows.old (admin + exact path)'
        )
        StartupDisableSafe = @(
            'MicrosoftEdgeAutoLaunch_*',
            'Teams',
            'GoogleChromeAutoLaunch_*',
            'Outlook auto-start',
            'DevHome auto-start',
            'PC Manager auto-start'
        )
        ScheduledTasksDisable = @($scheduledTasks)
        ServiceAdjustments = @($serviceAdjustments)
        RegistryFixes = @(
            'Disable ContentDeliveryManager suggestions',
            'Disable Edge background mode/startup boost',
            'Disable widgets/feed taskbar integration',
            'Ensure Windows Game Mode is enabled'
        )
        SessionProfiles = [ordered]@{
            HANDHELD = 'game-handheld'
            DOCKED_TV = 'game-docked'
            DOCKED_MONITOR = 'desktop'
        }
        KillInGame = @('ms-teams', 'olk', 'PhoneExperienceHost', 'msedge', 'Widgets', 'WidgetService')
        KeepAlways = @('SecurityHealthSystray', 'RadeonSoftware', 'Steam', 'Sunshine', 'Tailscale', 'PowerControl', 'PerformanceOverlay', 'SteamController')
        AppxRemove = @($appxRemove)
        Verify = @(
            'startup snapshot',
            'services snapshot',
            'tasks snapshot',
            'appx snapshot',
            'policy report'
        )
    }
}

function Get-BootstrapDataRoot {
    return (Join-Path $env:USERPROFILE '.bootstrap-tools')
}

function Get-BootstrapSteamDeckSettingsPath {
    return (Join-Path (Get-BootstrapDataRoot) 'steamdeck-settings.json')
}

function Get-BootstrapSteamDeckAutomationRoot {
    return (Join-Path (Join-Path (Get-BootstrapDataRoot) 'steamdeck') 'automation')
}

function Get-BootstrapSteamDeckAssetsRoot {
    return (Join-Path $PSScriptRoot 'assets\steamdeck\automation')
}

function Get-BootstrapResolvedSteamDeckVersion {
    param([string]$RequestedVersion = 'Auto')

    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion) -and $RequestedVersion -ine 'Auto') {
        return $RequestedVersion.ToLowerInvariant()
    }

    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $manufacturer = [string]$computerSystem.Manufacturer
        $model = [string]$computerSystem.Model
        if ($manufacturer -match 'Valve') {
            if ($model -match 'Jupiter') { return 'lcd' }
            if ($model -match 'Galileo') { return 'oled' }
        }
    } catch {
    }

    try {
        $display = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | Select-Object -First 1
        if ($display) {
            $manufacturer = -join ($display.ManufacturerName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
            $product = -join ($display.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
            if ($manufacturer -eq 'VLV' -and $product -eq 'ANX7530 U') {
                return 'lcd'
            }
        }
    } catch {
    }

    return 'lcd'
}

function Get-BootstrapSteamDeckSettingsDefaults {
    param([string]$ResolvedSteamDeckVersion = 'lcd')

    return [ordered]@{
        steamDeckVersion = 'Auto'
        resolvedSteamDeckVersion = if ([string]::IsNullOrWhiteSpace($ResolvedSteamDeckVersion)) { 'lcd' } else { $ResolvedSteamDeckVersion }
        internalDisplay = [ordered]@{
            manufacturer = 'VLV'
            product = 'ANX7530 U'
        }
        monitorProfiles = @()
        monitorFamilies = @(
            [ordered]@{
                manufacturer = 'GSM'
                product = 'LG HDR WFHD'
                mode = 'DOCKED_MONITOR'
                layout = 'lg-hdr-wfhd'
                resolutionPolicy = 'native-prefer-1440p-else-1080p'
            }
        )
        genericExternal = [ordered]@{
            mode = 'DOCKED_TV'
            resolutionPolicy = '1920x1080-safe'
            layout = 'external-generic'
        }
        audioTargets = [ordered]@{
            handheld = @('Speaker', 'Steam Streaming Speakers')
            dockMonitor = @('HDMI', 'DisplayPort', 'LG HDR WFHD')
            dockTv = @('HDMI', 'DisplayPort', 'TV')
        }
        handheld = [ordered]@{
            resolution = '1280x800'
            refreshHz = 60
            taskbarMode = 'autohide'
            inputProfile = 'handheld'
            gyroEnabled = $true
        }
        dockMonitor = [ordered]@{
            resolutionPolicy = 'native-prefer-1440p-else-1080p'
            taskbarMode = 'desktop'
            inputProfile = 'desktop'
            gyroEnabled = $false
            layout = 'lg-hdr-wfhd'
        }
        dockTv = [ordered]@{
            resolutionPolicy = '1920x1080-safe'
            taskbarMode = 'desktop'
            inputProfile = 'hybrid'
            gyroEnabled = $false
            layout = 'external-generic'
        }
        sessionProfiles = [ordered]@{
            HANDHELD = 'game-handheld'
            DOCKED_TV = 'game-docked'
            DOCKED_MONITOR = 'desktop'
        }
        hostHealth = [ordered]@{
            mode = 'off'
            killInGame = @('ms-teams', 'olk', 'PhoneExperienceHost', 'msedge', 'Widgets', 'WidgetService')
            keepAlways = @('SecurityHealthSystray', 'RadeonSoftware', 'Steam', 'Sunshine', 'Tailscale', 'PowerControl', 'PerformanceOverlay', 'SteamController')
        }
        manualOverrides = [ordered]@{
            forcedMode = $null
            expiresAt = $null
        }
    }
}

function Normalize-BootstrapSteamDeckSettingsData {
    param($Settings)

    $normalized = ConvertTo-BootstrapHashtable -InputObject $Settings
    if (-not ($normalized -is [hashtable])) {
        $normalized = @{}
    }

    $normalized['monitorProfiles'] = @(Normalize-BootstrapObjectArray -Value ($normalized['monitorProfiles']))
    $normalized['monitorFamilies'] = @(Normalize-BootstrapObjectArray -Value ($normalized['monitorFamilies']))

    if (-not $normalized.ContainsKey('sessionProfiles')) {
        $normalized['sessionProfiles'] = @{
            HANDHELD = 'game-handheld'
            DOCKED_TV = 'game-docked'
            DOCKED_MONITOR = 'desktop'
        }
    }

    if (-not $normalized.ContainsKey('hostHealth')) {
        $normalized['hostHealth'] = @{
            mode = 'off'
            killInGame = @('ms-teams', 'olk', 'PhoneExperienceHost', 'msedge', 'Widgets', 'WidgetService')
            keepAlways = @('SecurityHealthSystray', 'RadeonSoftware', 'Steam', 'Sunshine', 'Tailscale', 'PowerControl', 'PerformanceOverlay', 'SteamController')
        }
    }

    return $normalized
}

function Get-BootstrapSteamDeckSettingsData {
    param(
        [string]$RequestedSteamDeckVersion = 'Auto',
        [string]$ResolvedSteamDeckVersion = 'lcd'
    )

    $settingsPath = Get-BootstrapSteamDeckSettingsPath
    $current = $null
    if (Test-Path $settingsPath) {
        try {
            $current = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $current = $null
        }
    }

    $merged = Merge-BootstrapData -Defaults (Get-BootstrapSteamDeckSettingsDefaults -ResolvedSteamDeckVersion $ResolvedSteamDeckVersion) -Current $current
    $merged = Normalize-BootstrapSteamDeckSettingsData -Settings $merged
    $merged['steamDeckVersion'] = $RequestedSteamDeckVersion
    $merged['resolvedSteamDeckVersion'] = $ResolvedSteamDeckVersion

    return [ordered]@{
        Path = $settingsPath
        Data = $merged
    }
}

function Backup-BootstrapFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }

    $backupPath = '{0}.{1:yyyyMMdd_HHmmss}.bak' -f $Path, (Get-Date)
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function Save-BootstrapSteamDeckSettingsData {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [switch]$CreateBackup
    )

    $settingsPath = Get-BootstrapSteamDeckSettingsPath
    $normalized = Normalize-BootstrapSteamDeckSettingsData -Settings $Settings
    $backupPath = $null
    if ($CreateBackup) {
        $backupPath = Backup-BootstrapFile -Path $settingsPath
    }

    Write-BootstrapJsonFile -Path $settingsPath -Value $normalized

    return [ordered]@{
        Path = $settingsPath
        BackupPath = $backupPath
    }
}

function Ensure-BootstrapSteamDeckSettings {
    param([hashtable]$State)

    $dataRoot = Get-BootstrapDataRoot
    $settingsPath = Get-BootstrapSteamDeckSettingsPath
    $null = New-Item -Path $dataRoot -ItemType Directory -Force

    $current = $null
    if (Test-Path $settingsPath) {
        try {
            $current = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log "Falha ao ler $settingsPath. Os defaults do Steam Deck serao regravados." 'WARN'
        }
    }

    $merged = Merge-BootstrapData -Defaults (Get-BootstrapSteamDeckSettingsDefaults -ResolvedSteamDeckVersion $State.ResolvedSteamDeckVersion) -Current $current
    $merged = Normalize-BootstrapSteamDeckSettingsData -Settings $merged
    $merged.steamDeckVersion = $State.RequestedSteamDeckVersion
    $merged.resolvedSteamDeckVersion = $State.ResolvedSteamDeckVersion
    (ConvertTo-BootstrapObjectGraph -InputObject $merged) | ConvertTo-Json -Depth 12 | Set-Content -Path $settingsPath -Encoding utf8
    $State.SteamDeckSettingsPath = $settingsPath
    Write-Log "Config do Steam Deck garantida: $settingsPath"

    return $settingsPath
}

function Ensure-BootstrapSteamDeckWatcherTask {
    param([hashtable]$State)

    $watcherScript = Join-Path $State.SteamDeckAutomationRoot 'ModeWatcher.ps1'
    if (-not (Test-Path $watcherScript)) { return }

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $powershellExe)) {
        Write-Log 'Nao foi possivel localizar powershell.exe para registrar o watcher do Steam Deck.' 'WARN'
        return
    }

    $taskName = 'BootstrapTools-SteamDeckModeWatcher'
    $taskCommand = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -SettingsPath "{2}"' -f $powershellExe, $watcherScript, $State.SteamDeckSettingsPath)
    $schtasksExe = Resolve-CommandPath -Name 'schtasks.exe'
    if (-not $schtasksExe) { $schtasksExe = Join-Path $env:SystemRoot 'System32\schtasks.exe' }
    if (-not (Test-Path $schtasksExe)) {
        Write-Log 'schtasks.exe nao encontrado. O watcher do Steam Deck nao foi registrado.' 'WARN'
        return
    }

    $exitCode = Invoke-NativeWithLog -Exe $schtasksExe -Args @('/Create', '/SC', 'ONLOGON', '/TN', $taskName, '/TR', $taskCommand, '/F')
    if ($exitCode -ne 0) {
        Write-Log "Falha ao registrar a tarefa $taskName (exit=$exitCode)." 'WARN'
        return
    }

    Write-Log "Watcher do Steam Deck registrado: $taskName"
}

function Ensure-BootstrapSteamDeckAutomation {
    param([hashtable]$State)

    $settingsPath = Ensure-BootstrapSteamDeckSettings -State $State
    $sourceRoot = Get-BootstrapSteamDeckAssetsRoot
    $targetRoot = Get-BootstrapSteamDeckAutomationRoot

    if (-not (Test-Path $sourceRoot)) {
        throw "Assets de automacao do Steam Deck nao encontrados em: $sourceRoot"
    }

    $null = New-Item -Path $targetRoot -ItemType Directory -Force
    Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $targetRoot -Force -Recurse
    $State.SteamDeckAutomationRoot = $targetRoot
    $State.SteamDeckSettingsPath = $settingsPath

    Ensure-BootstrapSteamDeckWatcherTask -State $State
    Write-Log "Automacao do Steam Deck garantida: $targetRoot"
}

function Test-BootstrapManualRequirementInstalled {
    param([Parameter(Mandatory = $true)]$ComponentDef)

    if ($ComponentDef.PSObject.Properties.Name -contains 'CheckCommand') {
        $commandPath = Resolve-CommandPath -Name $ComponentDef.CheckCommand
        if ($commandPath) { return $true }
    }

    if ($ComponentDef.PSObject.Properties.Name -contains 'ProbePaths') {
        foreach ($path in @($ComponentDef.ProbePaths)) {
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            if (Test-Path $ExecutionContext.InvokeCommand.ExpandString($path)) {
                return $true
            }
        }
    }

    return $false
}

function Ensure-BootstrapManualRequirement {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$ComponentDef
    )

    if (Test-BootstrapManualRequirementInstalled -ComponentDef $ComponentDef) {
        Write-Log "$($ComponentDef.DisplayName) ja esta presente no host."
        return
    }

    $instructions = if ($ComponentDef.PSObject.Properties.Name -contains 'Instructions') { [string]$ComponentDef.Instructions } else { 'Instale manualmente e rode o bootstrap novamente.' }
    throw ("Dependencia manual obrigatoria ausente: {0}. {1}" -f $ComponentDef.DisplayName, $instructions)
}

function Get-BootstrapComponentStage {
    param([Parameter(Mandatory = $true)]$ComponentDef)

    if ($ComponentDef.PSObject.Properties.Name -contains 'Stage') {
        return ([string]$ComponentDef.Stage).ToLowerInvariant()
    }

    switch ($ComponentDef.Kind) {
        'system-core' { return 'runtime' }
        'git-core' { return 'runtime' }
        'node-core' { return 'runtime' }
        'python-core' { return 'runtime' }
        'wsl-core' { return 'runtime' }
        'steamdeck-settings' { return 'config' }
        'steamdeck-automation' { return 'config' }
        'manual-required' { return 'verify' }
        default { return 'payload' }
    }
}

function Get-BootstrapUsesSteamDeckFlow {
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)]$Resolution
    )

    foreach ($name in @($Selection.Profiles) + @($Selection.Components) + @($Resolution.ExpandedProfiles) + @($Resolution.ResolvedComponents)) {
        if (-not [string]::IsNullOrWhiteSpace($name) -and $name.ToLowerInvariant().StartsWith('steamdeck-')) {
            return $true
        }
    }

    return $false
}

function Get-BootstrapComponentCatalog {
    $catalog = [ordered]@{}

    $catalog['system-core'] = New-BootstrapComponentDefinition -Name 'system-core' -Description 'Base do sistema: log, proxy e winget.' -Optional $false -Kind 'system-core'
    $catalog['git-core'] = New-BootstrapComponentDefinition -Name 'git-core' -Description 'Git for Windows e Git Bash.' -DependsOn @('system-core') -Optional $false -Kind 'git-core'
    $catalog['git-lfs'] = New-BootstrapComponentDefinition -Name 'git-lfs' -Description 'Git LFS e inicialização local.' -DependsOn @('git-core') -Kind 'git-lfs'
    $catalog['node-core'] = New-BootstrapComponentDefinition -Name 'node-core' -Description 'Node.js LTS e npm global bin.' -DependsOn @('system-core') -Optional $false -Kind 'node-core'
    $catalog['python-core'] = New-BootstrapComponentDefinition -Name 'python-core' -Description 'Python 3.13, PATH e uv.' -DependsOn @('system-core') -Optional $false -Kind 'python-core'
    $catalog['java-core'] = New-BootstrapComponentDefinition -Name 'java-core' -Description 'Temurin JDK 17.' -DependsOn @('system-core') -Optional $false -Kind 'winget' -Data @{ Id = 'EclipseAdoptium.Temurin.17.JDK'; DisplayName = 'Java JDK (Temurin 17)' }
    $catalog['imagemagick'] = New-BootstrapComponentDefinition -Name 'imagemagick' -Description 'ImageMagick.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'ImageMagick.ImageMagick'; DisplayName = 'ImageMagick' }
    $catalog['sevenzip'] = New-BootstrapComponentDefinition -Name 'sevenzip' -Description '7-Zip e ajuste de PATH.' -DependsOn @('system-core') -Kind 'sevenzip'
    $catalog['powershell'] = New-BootstrapComponentDefinition -Name 'powershell' -Description 'PowerShell 7.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.PowerShell'; DisplayName = 'PowerShell 7' }
    $catalog['terminal'] = New-BootstrapComponentDefinition -Name 'terminal' -Description 'Windows Terminal.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.WindowsTerminal'; DisplayName = 'Windows Terminal' }
    $catalog['powertoys'] = New-BootstrapComponentDefinition -Name 'powertoys' -Description 'Microsoft PowerToys.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.PowerToys'; DisplayName = 'Microsoft PowerToys' }
    $catalog['github-cli'] = New-BootstrapComponentDefinition -Name 'github-cli' -Description 'GitHub CLI (gh).' -DependsOn @('git-core') -Kind 'winget' -Data @{ Id = 'GitHub.cli'; DisplayName = 'GitHub CLI (gh)' }
    $catalog['chrome'] = New-BootstrapComponentDefinition -Name 'chrome' -Description 'Google Chrome.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Google.Chrome'; DisplayName = 'Google Chrome'; AllowFailureWhenNotAdmin = $true }
    $catalog['google-app-desktop'] = New-BootstrapComponentDefinition -Name 'google-app-desktop' -Description 'Google App para Desktop.' -Kind 'manual-required' -Data @{ DisplayName = 'Google App Desktop'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Experiência oficial do Google no Windows.'; Instructions = 'Instale acessando https://search.google/google-app/desktop/?utm_source=Google&utm_medium=keyword_blog&utm_campaign=DGA_blog' }
    $catalog['notepadpp'] = New-BootstrapComponentDefinition -Name 'notepadpp' -Description 'Notepad++.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Notepad++.Notepad++'; DisplayName = 'Notepad++'; AllowFailureWhenNotAdmin = $true }
    $catalog['wsl-core'] = New-BootstrapComponentDefinition -Name 'wsl-core' -Description 'Recursos WSL, Ubuntu e WSL 2.' -DependsOn @('system-core') -Kind 'wsl-core'
    $catalog['wsl-ui'] = New-BootstrapComponentDefinition -Name 'wsl-ui' -Description 'WSL UI e WebView2.' -DependsOn @('wsl-core') -Kind 'wsl-ui'
    $catalog['docker'] = New-BootstrapComponentDefinition -Name 'docker' -Description 'Docker Desktop.' -DependsOn @('wsl-core') -Kind 'winget' -Data @{ Id = 'Docker.DockerDesktop'; DisplayName = 'Docker Desktop' }
    $catalog['claude-desktop'] = New-BootstrapComponentDefinition -Name 'claude-desktop' -Description 'Claude Desktop.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Anthropic.Claude'; DisplayName = 'Claude Desktop'; AllowFailureWhenNotAdmin = $true }
    $catalog['claude-code'] = New-BootstrapComponentDefinition -Name 'claude-code' -Description 'Claude Code CLI.' -DependsOn @('system-core') -Kind 'claude-code'
    $catalog['cursor'] = New-BootstrapComponentDefinition -Name 'cursor' -Description 'Cursor.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Anysphere.Cursor'; DisplayName = 'Cursor'; AllowFailureWhenNotAdmin = $true }
    $catalog['windsurf'] = New-BootstrapComponentDefinition -Name 'windsurf' -Description 'Windsurf.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Codeium.Windsurf'; DisplayName = 'Windsurf'; AllowFailureWhenNotAdmin = $true }
    $catalog['warp'] = New-BootstrapComponentDefinition -Name 'warp' -Description 'Warp terminal.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Warp.Warp'; DisplayName = 'Warp'; AllowFailureWhenNotAdmin = $true }
    $catalog['trae'] = New-BootstrapComponentDefinition -Name 'trae' -Description 'Trae desktop.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'ByteDance.Trae'; DisplayName = 'Trae'; AllowFailureWhenNotAdmin = $true }
    $catalog['opencode-desktop'] = New-BootstrapComponentDefinition -Name 'opencode-desktop' -Description 'OpenCode Desktop.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'SST.OpenCodeDesktop'; DisplayName = 'OpenCode Desktop'; AllowFailureWhenNotAdmin = $true }
    $catalog['vscode-insiders'] = New-BootstrapComponentDefinition -Name 'vscode-insiders' -Description 'VS Code Insiders.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.VisualStudioCode.Insiders'; DisplayName = 'Visual Studio Code - Insiders'; AllowFailureWhenNotAdmin = $true }
    $catalog['antigravity'] = New-BootstrapComponentDefinition -Name 'antigravity' -Description 'Google Antigravity.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Google.Antigravity'; DisplayName = 'Antigravity'; AllowFailureWhenNotAdmin = $true }
    $catalog['autoclaw'] = New-BootstrapComponentDefinition -Name 'autoclaw' -Description 'AutoClaw.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'ZhipuAI.AutoClaw'; DisplayName = 'AutoClaw'; AllowFailureWhenNotAdmin = $true }
    $catalog['perplexity'] = New-BootstrapComponentDefinition -Name 'perplexity' -Description 'Perplexity Comet.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Perplexity.Comet'; DisplayName = 'Perplexity'; AllowFailureWhenNotAdmin = $true }
    $catalog['codex-installer'] = New-BootstrapComponentDefinition -Name 'codex-installer' -Description 'Codex installer desktop via winget.' -DependsOn @('system-core') -Kind 'codex-installer'
    $catalog['ollama'] = New-BootstrapComponentDefinition -Name 'ollama' -Description 'Ollama local.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Ollama.Ollama'; DisplayName = 'Ollama' }
    $catalog['cherry-studio'] = New-BootstrapComponentDefinition -Name 'cherry-studio' -Description 'Cherry Studio.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'kangfenmao.CherryStudio'; DisplayName = 'Cherry Studio' }
    $catalog['lm-studio'] = New-BootstrapComponentDefinition -Name 'lm-studio' -Description 'LM Studio local LLM.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'LMStudio.LMStudio'; DisplayName = 'LM Studio' }
    $catalog['pinokio'] = New-BootstrapComponentDefinition -Name 'pinokio' -Description 'Pinokio AI Browser.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Pinokio.Pinokio'; DisplayName = 'Pinokio' }
    $catalog['zed'] = New-BootstrapComponentDefinition -Name 'zed' -Description 'Zed editor.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'ZedIndustries.Zed'; DisplayName = 'Zed' }
    $catalog['opencode'] = New-BootstrapComponentDefinition -Name 'opencode' -Description 'OpenCode CLI via script oficial.' -DependsOn @('git-core') -Kind 'opencode'
    $catalog['gemini-cli'] = New-BootstrapComponentDefinition -Name 'gemini-cli' -Description 'Gemini CLI via npm -g.' -DependsOn @('node-core') -Kind 'npm' -Data @{ Package = '@google/gemini-cli'; DisplayName = 'Gemini CLI (@google/gemini-cli)' }
    $catalog['bonsai-cli'] = New-BootstrapComponentDefinition -Name 'bonsai-cli' -Description 'Bonsai CLI via npm -g.' -DependsOn @('node-core') -Kind 'npm' -Data @{ Package = '@bonsai-ai/cli'; DisplayName = 'Bonsai CLI (@bonsai-ai/cli)' }
    $catalog['grok-cli'] = New-BootstrapComponentDefinition -Name 'grok-cli' -Description 'Grok CLI via npm -g.' -DependsOn @('node-core') -Kind 'npm' -Data @{ Package = '@vibe-kit/grok-cli'; DisplayName = 'Grok CLI (@vibe-kit/grok-cli)' }
    $catalog['qwen-code'] = New-BootstrapComponentDefinition -Name 'qwen-code' -Description 'Qwen Code via npm -g.' -DependsOn @('node-core') -Kind 'npm' -Data @{ Package = '@qwen-code/qwen-code@latest'; DisplayName = 'Qwen Code (@qwen-code/qwen-code)' }
    $catalog['copilot-cli'] = New-BootstrapComponentDefinition -Name 'copilot-cli' -Description 'GitHub Copilot CLI via npm -g.' -DependsOn @('node-core') -Kind 'npm' -Data @{ Package = '@github/copilot'; DisplayName = 'GitHub Copilot CLI (@github/copilot)' }
    $catalog['codex-cli'] = New-BootstrapComponentDefinition -Name 'codex-cli' -Description 'OpenAI Codex CLI via npm -g.' -DependsOn @('node-core') -Kind 'npm' -Data @{ Package = '@openai/codex'; DisplayName = 'OpenAI Codex CLI (@openai/codex)' }
    $catalog['openclaw'] = New-BootstrapComponentDefinition -Name 'openclaw' -Description 'OpenClaw via npm.' -DependsOn @('node-core') -Kind 'openclaw'
    $catalog['claude-config'] = New-BootstrapComponentDefinition -Name 'claude-config' -Description 'Defaults e hooks do Claude Code.' -DependsOn @('git-core', 'claude-code') -Kind 'claude-config'
    $catalog['aider'] = New-BootstrapComponentDefinition -Name 'aider' -Description 'aider via uv tool.' -DependsOn @('python-core') -Kind 'uvtool' -Data @{ Package = 'aider-chat'; CommandName = 'aider'; DisplayName = 'aider (aider-chat)'; VersionArgs = @('--version') }
    $catalog['goose'] = New-BootstrapComponentDefinition -Name 'goose' -Description 'goose CLI.' -DependsOn @('git-core') -Kind 'goose'
    $catalog['repo-gemini-cli'] = New-BootstrapComponentDefinition -Name 'repo-gemini-cli' -Description 'Clone do repositório gemini-cli.' -DependsOn @('git-core') -Kind 'repo-clone' -Data @{ RepoUrl = 'https://github.com/heartyguy/gemini-cli'; TargetName = 'gemini-cli' }
    $catalog['n8n'] = New-BootstrapComponentDefinition -Name 'n8n' -Description 'n8n global via npm.' -DependsOn @('node-core') -Kind 'npm' -Data @{ Package = 'n8n'; DisplayName = 'n8n' }
    $catalog['autohotkey'] = New-BootstrapComponentDefinition -Name 'autohotkey' -Description 'AutoHotkey.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'AutoHotkey.AutoHotkey'; DisplayName = 'AutoHotkey' }
    $catalog['blender'] = New-BootstrapComponentDefinition -Name 'blender' -Description 'Blender LTS.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'BlenderFoundation.Blender.LTS.4.5'; DisplayName = 'Blender LTS 4.5' }
    $catalog['ffmpeg'] = New-BootstrapComponentDefinition -Name 'ffmpeg' -Description 'FFmpeg.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Gyan.FFmpeg'; DisplayName = 'FFmpeg' }
    $catalog['unity-hub'] = New-BootstrapComponentDefinition -Name 'unity-hub' -Description 'Unity Hub.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Unity.UnityHub'; DisplayName = 'Unity Hub' }
    $catalog['cmake'] = New-BootstrapComponentDefinition -Name 'cmake' -Description 'CMake.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Kitware.CMake'; DisplayName = 'CMake' }
    $catalog['llvm'] = New-BootstrapComponentDefinition -Name 'llvm' -Description 'LLVM.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'LLVM.LLVM'; DisplayName = 'LLVM' }
    $catalog['rustup'] = New-BootstrapComponentDefinition -Name 'rustup' -Description 'Rustup.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Rustlang.Rustup'; DisplayName = 'Rustup' }
    $catalog['visual-studio-community'] = New-BootstrapComponentDefinition -Name 'visual-studio-community' -Description 'Visual Studio Community 2022.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.VisualStudio.2022.Community'; DisplayName = 'Visual Studio Community 2022' }
    $catalog['steam'] = New-BootstrapComponentDefinition -Name 'steam' -Description 'Steam.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Valve.Steam'; DisplayName = 'Steam' }
    $catalog['steamcmd'] = New-BootstrapComponentDefinition -Name 'steamcmd' -Description 'SteamCMD.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Valve.SteamCMD'; DisplayName = 'SteamCMD' }
    $catalog['autohotkey-runtime'] = New-BootstrapComponentDefinition -Name 'autohotkey-runtime' -Description 'Runtime base para hotkeys e fallback manual do Steam Deck.' -DependsOn @('autohotkey') -Kind 'alias' -Data @{ Stage = 'runtime'; Provisioning = 'winget'; ValueReason = 'Permite hotkeys fisicos e fallback local sem depender do Steam.' }
    $catalog['powershell-core-runtime'] = New-BootstrapComponentDefinition -Name 'powershell-core-runtime' -Description 'PowerShell Core pronto para componentes futuros.' -DependsOn @('powershell') -Kind 'alias' -Data @{ Stage = 'runtime'; Provisioning = 'winget'; ValueReason = 'Provisiona pwsh antes de qualquer componente futuro que precise dele.' }
    $catalog['vigembus-runtime'] = New-BootstrapComponentDefinition -Name 'vigembus-runtime' -Description 'Barramento virtual usado por ferramentas de input do Steam Deck.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'ViGEm.ViGEmBus'; DisplayName = 'ViGEmBus'; Stage = 'runtime'; Provisioning = 'winget'; ValueReason = 'Base para emulacao/ponte de controle no modo handheld.' }
    $catalog['steamdeck-tools-runtime'] = New-BootstrapComponentDefinition -Name 'steamdeck-tools-runtime' -Description 'Steam Deck Tools portatil com servicos de controle e overlay.' -DependsOn @('system-core', 'vigembus-runtime') -Kind 'steamdeck-tools' -Data @{ Stage = 'runtime'; Provisioning = 'download'; ValueReason = 'Entrega overlay, controle, fan e power tuning especificos do Deck.' }
    $catalog['displayfusion'] = New-BootstrapComponentDefinition -Name 'displayfusion' -Description 'Layout de monitores e perfis de dock.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'BinaryFortress.DisplayFusion'; DisplayName = 'DisplayFusion'; Stage = 'runtime'; Provisioning = 'winget'; ValueReason = 'Permite layouts dedicados para monitor externo e dock.' }
    $catalog['soundswitch'] = New-BootstrapComponentDefinition -Name 'soundswitch' -Description 'Troca rapida de audio entre Deck e HDMI/DP.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'AntoineAflalo.SoundSwitch'; DisplayName = 'SoundSwitch'; Stage = 'runtime'; Provisioning = 'winget'; ValueReason = 'Redireciona audio automaticamente entre handheld e dock.' }
    $catalog['steamdeck-settings'] = New-BootstrapComponentDefinition -Name 'steamdeck-settings' -Description 'Cria e mantem steamdeck-settings.json com defaults e families.' -DependsOn @('system-core') -Kind 'steamdeck-settings' -Data @{ Stage = 'config'; Provisioning = 'builtin'; ValueReason = 'Persiste os defaults do host, incluindo a familia GSM/LG HDR WFHD e o fallback generico.' }
    $catalog['steamdeck-automation'] = New-BootstrapComponentDefinition -Name 'steamdeck-automation' -Description 'Provisiona watcher handheld/dock, scripts Apply-* e hotkeys.' -DependsOn @('steamdeck-settings', 'autohotkey-runtime', 'displayfusion', 'soundswitch', 'steamdeck-tools-runtime') -Kind 'steamdeck-automation' -Data @{ Stage = 'config'; Provisioning = 'builtin'; ValueReason = 'Ativa a deteccao por familia de monitor e o fallback generico sem quebrar a experiencia dock.' }
    $catalog['playnite'] = New-BootstrapComponentDefinition -Name 'playnite' -Description 'Frontend unificado para bibliotecas e modo console.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Playnite.Playnite'; DisplayName = 'Playnite'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Entrega um frontend fullscreen amigavel a controle no Deck.' }
    $catalog['heroic'] = New-BootstrapComponentDefinition -Name 'heroic' -Description 'Cliente Epic/GOG leve para o Deck.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'HeroicGamesLauncher.HeroicGamesLauncher'; DisplayName = 'Heroic Games Launcher'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Cobre bibliotecas Epic/GOG sem depender do launcher oficial pesado.' }
    $catalog['rtss'] = New-BootstrapComponentDefinition -Name 'rtss' -Description 'RivaTuner Statistics Server para overlay e frame pacing.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Guru3D.RTSS'; DisplayName = 'RivaTuner Statistics Server'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Entrega overlay e base para performance tuning no Deck.' }
    $catalog['special-k'] = New-BootstrapComponentDefinition -Name 'special-k' -Description 'Special K para HDR, pacing e latencia.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'SpecialK.SpecialK'; DisplayName = 'Special K'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Ajuda a estabilizar frame pacing e recursos visuais em jogos Windows no Deck.' }
    $catalog['vcpp-redist'] = New-BootstrapComponentDefinition -Name 'vcpp-redist' -Description 'Visual C++ Redistributable 2015+ x64.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.VCRedist.2015+.x64'; DisplayName = 'Microsoft Visual C++ Redistributable 2015+ x64'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Evita falhas por runtime ausente em launchers, overlays e jogos.' }
    $catalog['directx-runtime'] = New-BootstrapComponentDefinition -Name 'directx-runtime' -Description 'DirectX runtime legado para jogos e ferramentas.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.DirectX'; DisplayName = 'Microsoft DirectX Runtime'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Fecha dependencias comuns de jogos Windows em instalacoes novas.' }
    $catalog['sunshine'] = New-BootstrapComponentDefinition -Name 'sunshine' -Description 'Servidor de game streaming.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'LizardByte.Sunshine'; DisplayName = 'Sunshine'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Transforma o Deck dockado em host de streaming sem abrir portas manualmente.' }
    $catalog['moonlight'] = New-BootstrapComponentDefinition -Name 'moonlight' -Description 'Cliente para streaming Sunshine/GameStream.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'MoonlightGameStreamingProject.Moonlight'; DisplayName = 'Moonlight'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Facilita testes e acesso remoto ao ecossistema do Deck.' }
    $catalog['tailscale'] = New-BootstrapComponentDefinition -Name 'tailscale' -Description 'VPN mesh para acesso remoto seguro.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Tailscale.Tailscale'; DisplayName = 'Tailscale'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Conecta o Deck remotamente sem expor servicos publicamente.' }
    $catalog['scrcpy'] = New-BootstrapComponentDefinition -Name 'scrcpy' -Description 'Espelha e controla Android no Deck.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Genymobile.scrcpy'; DisplayName = 'scrcpy'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Ajuda na ponte mobile quando o Deck esta dockado ou em bancada.' }
    $catalog['syncthing'] = New-BootstrapComponentDefinition -Name 'syncthing' -Description 'Sincroniza saves e configuracoes entre maquinas.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Syncthing.Syncthing'; DisplayName = 'Syncthing'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Mantem saves/configs coerentes entre Deck e desktop.' }
    $catalog['chiaki'] = New-BootstrapComponentDefinition -Name 'chiaki' -Description 'Chiaki PS4/PS5 Remote Play.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'srwi.Chiaki'; DisplayName = 'Chiaki' }
    $catalog['rustdesk'] = New-BootstrapComponentDefinition -Name 'rustdesk' -Description 'RustDesk remote desktop.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'RustDesk.RustDesk'; DisplayName = 'RustDesk' }
    $catalog['quicklook'] = New-BootstrapComponentDefinition -Name 'quicklook' -Description 'Preview rapido de arquivos.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'QL-Win.QuickLook'; DisplayName = 'QuickLook'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Acelera inspeccao de arquivos em modo desktop e dock.' }
    $catalog['sharex'] = New-BootstrapComponentDefinition -Name 'sharex' -Description 'Captura e compartilhamento rapido.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'ShareX.ShareX'; DisplayName = 'ShareX'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Facilita screenshots e uploads com atalhos do Deck.' }
    $catalog['quickcpu'] = New-BootstrapComponentDefinition -Name 'quickcpu' -Description 'Controle fino de CPU e energia.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'CoderBag.QuickCPUx64'; DisplayName = 'Quick CPU x64'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Ajuda a equilibrar consumo e desempenho no modo bateria.' }
    $catalog['explorerpatcher'] = New-BootstrapComponentDefinition -Name 'explorerpatcher' -Description 'Ajustes de shell do Windows para uso no Deck.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'valinet.ExplorerPatcher'; DisplayName = 'ExplorerPatcher'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Simplifica a UX do Windows em handheld e dock.' }
    $catalog['mica-for-everyone'] = New-BootstrapComponentDefinition -Name 'mica-for-everyone' -Description 'Camada visual do Windows mais limpa e consistente.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'MicaForEveryone.MicaForEveryone'; DisplayName = 'Mica For Everyone'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Deixa a interface do Windows menos carregada para uso no Deck.' }
    $catalog['compactgui'] = New-BootstrapComponentDefinition -Name 'compactgui' -Description 'Compacta instalacoes grandes para economizar espaco.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'IridiumIO.CompactGUI'; DisplayName = 'CompactGUI'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Reduz pressao de storage no SSD interno do Deck.' }
    $catalog['treesize-free'] = New-BootstrapComponentDefinition -Name 'treesize-free' -Description 'Analise rapida de uso de disco.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'JAMSoftware.TreeSize.Free'; DisplayName = 'TreeSize Free'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Mostra rapidamente o que esta consumindo espaco em SSD e SD.' }
    $catalog['obs-studio'] = New-BootstrapComponentDefinition -Name 'obs-studio' -Description 'Captura e producao de video.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'OBSProject.OBSStudio'; DisplayName = 'OBS Studio'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Cobre captura de gameplay e producao de conteudo no Deck.' }
    $catalog['driver-store-explorer'] = New-BootstrapComponentDefinition -Name 'driver-store-explorer' -Description 'Backup e auditoria do driver store.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'lostindark.DriverStoreExplorer'; DisplayName = 'Driver Store Explorer'; Stage = 'payload'; Provisioning = 'winget'; ValueReason = 'Ajuda a preservar drivers especificos do Deck para reinstalacao offline.' }
    $catalog['lossless-scaling'] = New-BootstrapComponentDefinition -Name 'lossless-scaling' -Description 'Frame generation pago e otimizado para jogos no Deck.' -Kind 'manual-required' -Data @{ DisplayName = 'Lossless Scaling'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Entrega ganho real de fluidez, mas exige compra/licenca no Steam.'; Instructions = 'Instale pelo Steam antes de rodar novamente o perfil ou exclua o componente.' }
    $catalog['macrium-reflect'] = New-BootstrapComponentDefinition -Name 'macrium-reflect' -Description 'Imagem golden do SSD para restore rapido.' -Kind 'manual-required' -Data @{ DisplayName = 'Macrium Reflect'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Cria uma imagem completa do Deck, mas exige instalacao/licenciamento manual.'; Instructions = 'Instale manualmente o Macrium Reflect antes de usar o perfil de backup.' }
    $catalog['joyshockmapper'] = New-BootstrapComponentDefinition -Name 'joyshockmapper' -Description 'Mapeamento fino de gyro e controles.' -Kind 'manual-required' -Data @{ DisplayName = 'JoyShockMapper'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Da granularidade extra ao gyro, mas ainda depende de instalacao manual segura.'; Instructions = 'Instale o JoyShockMapper manualmente ou exclua este componente se optar por usar apenas Steam Input/Steam Deck Tools.' }
    $catalog['vibrancegui'] = New-BootstrapComponentDefinition -Name 'vibrancegui' -Description 'Ajustes extras de vibrancia e saturacao.' -Kind 'manual-required' -Data @{ DisplayName = 'VibranceGUI'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Melhora saturacao no painel do Deck, mas a origem binaria precisa ser validada manualmente.'; Instructions = 'Valide e instale o VibranceGUI manualmente antes de rodar novamente.' }
    $catalog['steamdeck-driver-pack'] = New-BootstrapComponentDefinition -Name 'steamdeck-driver-pack' -Description 'Drivers especificos do Steam Deck para Windows.' -Kind 'manual-required' -Data @{ DisplayName = 'Steam Deck driver pack'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Mantem paridade com o ecossistema do Deck, mas o pacote de drivers precisa ser escolhido conforme LCD/OLED e baixado com validacao manual.'; Instructions = 'Baixe e instale os drivers do Steam Deck adequados ao seu modelo antes de rodar novamente.' }
    $catalog['obs-source-record-plugin'] = New-BootstrapComponentDefinition -Name 'obs-source-record-plugin' -Description 'Plugin Source Record para gravacao separada por fonte.' -Kind 'manual-required' -Data @{ DisplayName = 'OBS Source Record plugin'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'Aprimora captura multipista, mas o plugin precisa ser instalado manualmente.'; Instructions = 'Instale o plugin Source Record no OBS antes de usar o perfil de captura.' }
    $catalog['instant-replay'] = New-BootstrapComponentDefinition -Name 'instant-replay' -Description 'Preset para replay buffer/instant replay.' -DependsOn @('obs-studio') -Kind 'alias' -Data @{ Stage = 'config'; Provisioning = 'builtin'; ValueReason = 'Entrega um ponto de extensao para replay buffer sem introduzir outra dependencia agora.' }
    $catalog['pagefile-on-sd'] = New-BootstrapComponentDefinition -Name 'pagefile-on-sd' -Description 'Move pagefile para o SD ou unidade de apoio.' -Kind 'manual-required' -Data @{ DisplayName = 'Pagefile on SD'; Stage = 'verify'; Provisioning = 'manual-required'; ValueReason = 'E util para cenarios de storage apertado, mas e invasivo demais para habilitar automaticamente.'; Instructions = 'Ajuste manualmente o pagefile apos validar a unidade alvo e o impacto de desempenho.' }
    $catalog['workspace-layout'] = New-BootstrapComponentDefinition -Name 'workspace-layout' -Description 'Cria layout de DevKits e DevProjetos em F:.' -Kind 'workspace'

    $catalog['brave'] = New-BootstrapComponentDefinition -Name 'brave' -Description 'Brave Browser.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Brave.Brave'; DisplayName = 'Brave Browser'; AllowFailureWhenNotAdmin = $true }
    $catalog['discord'] = New-BootstrapComponentDefinition -Name 'discord' -Description 'Discord.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Discord.Discord'; DisplayName = 'Discord'; AllowFailureWhenNotAdmin = $true }
    $catalog['telegram'] = New-BootstrapComponentDefinition -Name 'telegram' -Description 'Telegram Desktop.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Telegram.TelegramDesktop'; DisplayName = 'Telegram Desktop'; AllowFailureWhenNotAdmin = $true }
    $catalog['1password'] = New-BootstrapComponentDefinition -Name '1password' -Description '1Password.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'AgileBits.1Password'; DisplayName = '1Password'; AllowFailureWhenNotAdmin = $true }
    $catalog['proton-drive'] = New-BootstrapComponentDefinition -Name 'proton-drive' -Description 'Proton Drive.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Proton.ProtonDrive'; DisplayName = 'Proton Drive'; AllowFailureWhenNotAdmin = $true }
    $catalog['proton-pass'] = New-BootstrapComponentDefinition -Name 'proton-pass' -Description 'Proton Pass.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Proton.ProtonPass'; DisplayName = 'Proton Pass'; AllowFailureWhenNotAdmin = $true }
    $catalog['pycharm-community'] = New-BootstrapComponentDefinition -Name 'pycharm-community' -Description 'PyCharm Community.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'JetBrains.PyCharm.Community'; DisplayName = 'PyCharm Community' }
    $catalog['dotnet-6-sdk'] = New-BootstrapComponentDefinition -Name 'dotnet-6-sdk' -Description 'Microsoft .NET 6.0 SDK.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.DotNet.SDK.6'; DisplayName = 'Microsoft .NET 6.0 SDK' }
    $catalog['fan-control'] = New-BootstrapComponentDefinition -Name 'fan-control' -Description 'Fan Control.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Rem0o.FanControl'; DisplayName = 'Fan Control' }
    $catalog['mem-reduct'] = New-BootstrapComponentDefinition -Name 'mem-reduct' -Description 'Mem Reduct.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'henrypp.memreduct'; DisplayName = 'Mem Reduct' }
    $catalog['jdownloader'] = New-BootstrapComponentDefinition -Name 'jdownloader' -Description 'JDownloader 2.' -DependsOn @('java-core') -Kind 'winget' -Data @{ Id = 'AppWork.JDownloader'; DisplayName = 'JDownloader 2'; AllowFailureWhenNotAdmin = $true }
    $catalog['dualboot-manager'] = New-BootstrapComponentDefinition -Name 'dualboot-manager' -Description 'Dual boot detection, safety guardrails and reboot management.' -DependsOn @('system-core') -Optional $true -Kind 'builtin' -Data @{}

    return $catalog
}

function Get-BootstrapProfileCatalog {
    $catalog = [ordered]@{}

    $catalog['legacy'] = New-BootstrapProfileDefinition -Name 'legacy' -Description 'Replica o fluxo atual do script.' -Items @('git-core', 'node-core', 'java-core', 'imagemagick', 'sevenzip', 'python-core', 'opencode', 'claude-code', 'github-cli', 'chrome', 'google-app-desktop', 'notepadpp', 'claude-desktop', 'cursor', 'windsurf', 'warp', 'trae', 'opencode-desktop', 'vscode-insiders', 'wsl-ui', 'antigravity', 'autoclaw', 'perplexity', 'codex-installer', 'gemini-cli', 'bonsai-cli', 'grok-cli', 'qwen-code', 'copilot-cli', 'codex-cli', 'openclaw', 'claude-config', 'aider', 'goose', 'repo-gemini-cli')
    $catalog['base'] = New-BootstrapProfileDefinition -Name 'base' -Description 'Base universal para máquina nova.' -Items @('git-core', 'git-lfs', 'node-core', 'python-core', 'java-core', 'imagemagick', 'sevenzip', 'powershell', 'terminal', 'powertoys', 'github-cli', 'chrome', 'google-app-desktop', 'brave', 'notepadpp')
    $catalog['containers'] = New-BootstrapProfileDefinition -Name 'containers' -Description 'WSL e Docker.' -Items @('wsl-core', 'wsl-ui', 'docker')
    $catalog['ai'] = New-BootstrapProfileDefinition -Name 'ai' -Description 'Desktops e CLIs de IA.' -Items @('claude-desktop', 'claude-code', 'cursor', 'windsurf', 'warp', 'trae', 'opencode-desktop', 'vscode-insiders', 'antigravity', 'autoclaw', 'perplexity', 'codex-installer', 'ollama', 'cherry-studio', 'lm-studio', 'pinokio', 'zed', 'opencode', 'gemini-cli', 'bonsai-cli', 'grok-cli', 'qwen-code', 'copilot-cli', 'codex-cli', 'openclaw', 'claude-config', 'aider', 'goose', 'repo-gemini-cli')
    $catalog['automation'] = New-BootstrapProfileDefinition -Name 'automation' -Description 'Automação local.' -Items @('n8n')
    $catalog['security'] = New-BootstrapProfileDefinition -Name 'security' -Description 'Gestores de senha e nuvem.' -Items @('1password', 'proton-drive', 'proton-pass')
    $catalog['social'] = New-BootstrapProfileDefinition -Name 'social' -Description 'Mensageiros e comunicação.' -Items @('discord', 'telegram')
    $catalog['utilities'] = New-BootstrapProfileDefinition -Name 'utilities' -Description 'Downloads e ferramentas de poweruser.' -Items @('jdownloader', 'fan-control', 'mem-reduct')
    $catalog['creator'] = New-BootstrapProfileDefinition -Name 'creator' -Description 'Ferramentas de criação e mídia.' -Items @('autohotkey', 'blender', 'ffmpeg')
    $catalog['game-dev'] = New-BootstrapProfileDefinition -Name 'game-dev' -Description 'Toolchain de jogos e compilação.' -Items @('unity-hub', 'cmake', 'llvm', 'rustup', 'visual-studio-community')
    $catalog['gaming'] = New-BootstrapProfileDefinition -Name 'gaming' -Description 'Steam e ferramentas relacionadas.' -Items @('steam', 'steamcmd')
    $catalog['steamdeck-essentials'] = New-BootstrapProfileDefinition -Name 'steamdeck-essentials' -Description 'Base handheld do Steam Deck em Windows.' -Items @('base', 'steam', 'playnite', 'heroic', 'rtss', 'special-k', 'vcpp-redist', 'directx-runtime', 'vigembus-runtime', 'steamdeck-tools-runtime', 'autohotkey-runtime')
    $catalog['steamdeck-input'] = New-BootstrapProfileDefinition -Name 'steamdeck-input' -Description 'Perfis de input, hotkeys e automacao de controle.' -Items @('steamdeck-settings', 'steamdeck-automation')
    $catalog['steamdeck-power'] = New-BootstrapProfileDefinition -Name 'steamdeck-power' -Description 'Gestao de energia e tuning para bateria/dock.' -Items @('powertoys', 'quickcpu', 'fan-control', 'mem-reduct')
    $catalog['steamdeck-dock'] = New-BootstrapProfileDefinition -Name 'steamdeck-dock' -Description 'Automacao handheld-dock com fallback generico.' -Items @('displayfusion', 'soundswitch', 'steamdeck-settings', 'steamdeck-automation')
    $catalog['steamdeck-storage'] = New-BootstrapProfileDefinition -Name 'steamdeck-storage' -Description 'Ferramentas de storage e auditoria.' -Items @('compactgui', 'treesize-free', 'pagefile-on-sd')
    $catalog['steamdeck-connectivity'] = New-BootstrapProfileDefinition -Name 'steamdeck-connectivity' -Description 'Streaming e conectividade remota do Deck.' -Items @('sunshine', 'moonlight', 'tailscale', 'scrcpy', 'syncthing', 'chiaki', 'rustdesk', 'dualboot-manager')
    $catalog['steamdeck-qol'] = New-BootstrapProfileDefinition -Name 'steamdeck-qol' -Description 'Melhorias de UX para desktop e handheld.' -Items @('quicklook', 'sharex', 'explorerpatcher', 'mica-for-everyone')
    $catalog['steamdeck-capture'] = New-BootstrapProfileDefinition -Name 'steamdeck-capture' -Description 'Captura de gameplay e replay buffer.' -Items @('obs-studio', 'obs-source-record-plugin', 'instant-replay')
    $catalog['steamdeck-backup'] = New-BootstrapProfileDefinition -Name 'steamdeck-backup' -Description 'Backup de drivers e imagem golden.' -Items @('driver-store-explorer', 'macrium-reflect')
    $catalog['steamdeck-recommended'] = New-BootstrapProfileDefinition -Name 'steamdeck-recommended' -Description 'Experiencia recomendada para este Steam Deck.' -Items @('steamdeck-essentials', 'steamdeck-input', 'steamdeck-power', 'steamdeck-dock', 'steamdeck-connectivity', 'steamdeck-qol')
    $catalog['steamdeck-full'] = New-BootstrapProfileDefinition -Name 'steamdeck-full' -Description 'Camada completa Steam Deck, incluindo storage/capture/backup e bloqueadores manuais.' -Items @('steamdeck-recommended', 'steamdeck-storage', 'steamdeck-capture', 'steamdeck-backup', 'lossless-scaling', 'joyshockmapper', 'vibrancegui', 'steamdeck-driver-pack')
    $catalog['workspace'] = New-BootstrapProfileDefinition -Name 'workspace' -Description 'Layout em F:\Steam\Steamapps e Dev.' -Items @('workspace-layout', 'pycharm-community', 'dotnet-6-sdk')
    $catalog['recommended'] = New-BootstrapProfileDefinition -Name 'recommended' -Description 'Perfis recomendados para sua máquina pessoal.' -Items @('base', 'containers', 'ai', 'creator', 'workspace', 'security', 'social', 'utilities')
    $catalog['full'] = New-BootstrapProfileDefinition -Name 'full' -Description 'Instala tudo.' -Items @('recommended', 'automation', 'game-dev', 'gaming')

    return $catalog
}

function Show-BootstrapProfiles {
    $profiles = Get-BootstrapProfileCatalog
    foreach ($profileName in $profiles.Keys) {
        $profileDef = $profiles[$profileName]
        Write-Output ("{0} - {1}" -f $profileDef.Name, $profileDef.Description)
    }
}

function Show-BootstrapComponents {
    $components = Get-BootstrapComponentCatalog
    foreach ($componentName in $components.Keys) {
        $componentDef = $components[$componentName]
        $depends = if ($componentDef.DependsOn.Count -gt 0) { $componentDef.DependsOn -join ', ' } else { '-' }
        $optional = if ($componentDef.Optional) { 'optional' } else { 'required' }
        Write-Output ("{0} - {1} | depends: {2} | {3}" -f $componentDef.Name, $componentDef.Description, $depends, $optional)
    }
}

function New-BootstrapSelectionObject {
    param(
        [string[]]$SelectedProfiles = @(),
        [string[]]$SelectedComponents = @(),
        [string[]]$ExcludedComponents = @(),
        [AllowNull()][string]$SelectedHostHealth = $null
    )

    $profiles = @(Normalize-BootstrapNames -Names $SelectedProfiles)
    $components = @(Normalize-BootstrapNames -Names $SelectedComponents)
    $excludes = @(Normalize-BootstrapNames -Names $ExcludedComponents)
    $hostHealth = Normalize-BootstrapHostHealthMode -Mode $SelectedHostHealth

    if ($profiles.Count -eq 0 -and $components.Count -eq 0) {
        $profiles = @('legacy')
    }

    return [pscustomobject]@{
        Profiles = @($profiles)
        Components = @($components)
        Excludes = @($excludes)
        HostHealth = $hostHealth
    }
}

function Get-BootstrapUiContract {
    $profiles = Get-BootstrapProfileCatalog
    $components = Get-BootstrapComponentCatalog

    $profileEntries = foreach ($profileName in $profiles.Keys) {
        $profileDef = $profiles[$profileName]
        [ordered]@{
            name = $profileDef.Name
            description = $profileDef.Description
            items = @($profileDef.Items)
        }
    }

    $componentEntries = foreach ($componentName in $components.Keys) {
        $componentDef = $components[$componentName]
        [ordered]@{
            name = $componentDef.Name
            description = $componentDef.Description
            dependsOn = @($componentDef.DependsOn)
            optional = [bool]$componentDef.Optional
            kind = [string]$componentDef.Kind
            stage = Get-BootstrapComponentStage -ComponentDef $componentDef
            valueReason = if ($componentDef.PSObject.Properties.Name -contains 'ValueReason') { [string]$componentDef.ValueReason } else { [string]$componentDef.Description }
        }
    }

    return [ordered]@{
        profileNames = @($profiles.Keys)
        componentNames = @($components.Keys)
        hostHealthModes = @(Get-BootstrapHostHealthModes)
        defaults = [ordered]@{
            workspaceRoot = 'F:\Steam\Steamapps'
            steamDeckVersion = 'Auto'
            uiLanguage = 'pt-BR'
            legacyHostHealth = 'off'
            modernHostHealth = 'conservador'
        }
        profiles = @($profileEntries)
        components = @($componentEntries)
        steamDeckSettingsDefaults = Get-BootstrapSteamDeckSettingsDefaults -ResolvedSteamDeckVersion 'lcd'
    }
}

function Get-BootstrapAdminReasons {
    param(
        [Parameter(Mandatory = $true)]$Resolution,
        [Parameter(Mandatory = $true)][string]$ResolvedHostHealthMode,
        [bool]$UsesSteamDeckFlow = $false
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $resolvedComponents = @($Resolution.ResolvedComponents)

    if ($resolvedComponents -contains 'wsl-core') {
        $reasons.Add('WSL e recursos opcionais do Windows podem exigir elevacao.')
    }

    if ($resolvedComponents -contains 'visual-studio-community') {
        $reasons.Add('Visual Studio Community normalmente pede elevacao para instalacao completa.')
    }

    if ($resolvedComponents -contains 'steamdeck-driver-pack') {
        $reasons.Add('Drivers especificos do Steam Deck exigem instalacao elevada.')
    }

    if ($UsesSteamDeckFlow -and ($resolvedComponents -contains 'steamdeck-tools-runtime')) {
        $reasons.Add('Executar como admin instala o Steam Deck Tools em Program Files; sem elevacao ele vai para o perfil do usuario.')
    }

    if ($ResolvedHostHealthMode -in @('conservador', 'equilibrado', 'agressivo')) {
        $reasons.Add('HostHealth usa elevacao para limpeza completa de C:\Windows\Temp, DISM e Windows.old.')
    }

    if ($ResolvedHostHealthMode -in @('equilibrado', 'agressivo')) {
        $reasons.Add('HostHealth pode precisar de elevacao para desabilitar tarefas agendadas do sistema.')
    }

    if ($ResolvedHostHealthMode -eq 'agressivo') {
        $reasons.Add('HostHealth agressivo ajusta servicos e requer elevacao.')
    }

    if (Test-BootstrapIsDualBoot) {
        $reasons.Add('Gestao e leitura de entradas UEFI/Dual Boot requer elevacao.')
    }

    return @($reasons.ToArray())
}

function Test-BootstrapComponentDependsOn {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [Parameter(Mandatory = $true)][string]$DependencyName,
        [Parameter(Mandatory = $true)]$Catalog,
        [hashtable]$Visited = @{}
    )

    if ($Visited.ContainsKey($ComponentName)) { return $false }
    $Visited[$ComponentName] = $true

    $componentDef = $Catalog[$ComponentName]
    if (-not $componentDef) { return $false }
    if ($componentDef.DependsOn -contains $DependencyName) { return $true }

    foreach ($dependency in $componentDef.DependsOn) {
        if (Test-BootstrapComponentDependsOn -ComponentName $dependency -DependencyName $DependencyName -Catalog $Catalog -Visited $Visited) {
            return $true
        }
    }

    return $false
}

function Resolve-BootstrapComponents {
    param(
        [string[]]$SelectedProfiles,
        [string[]]$SelectedComponents,
        [string[]]$ExcludedComponents
    )

    $profiles = Get-BootstrapProfileCatalog
    $components = Get-BootstrapComponentCatalog
    $requested = New-Object System.Collections.Generic.List[string]
    $expandedProfiles = New-Object System.Collections.Generic.List[string]

    function Add-ProfileItems {
        param([string]$ProfileName, [hashtable]$Stack)

        if (-not $profiles.Contains($ProfileName)) {
            throw "Perfil desconhecido: $ProfileName"
        }
        if ($Stack.ContainsKey($ProfileName)) {
            throw "Ciclo de perfis detectado: $ProfileName"
        }

        $Stack[$ProfileName] = $true
        if (-not $expandedProfiles.Contains($ProfileName)) {
            $expandedProfiles.Add($ProfileName)
        }

        foreach ($item in $profiles[$ProfileName].Items) {
            if ($profiles.Contains($item)) {
                Add-ProfileItems -ProfileName $item -Stack $Stack
            } else {
                if (-not $components.Contains($item)) {
                    throw "Item desconhecido no perfil ${ProfileName}: $item"
                }
                $requested.Add($item)
            }
        }

        $Stack.Remove($ProfileName) | Out-Null
    }

    foreach ($profileName in (Normalize-BootstrapNames -Names $SelectedProfiles)) {
        Add-ProfileItems -ProfileName $profileName -Stack @{}
    }

    foreach ($componentName in (Normalize-BootstrapNames -Names $SelectedComponents)) {
        if (-not $components.Contains($componentName)) {
            throw "Componente desconhecido: $componentName"
        }
        $requested.Add($componentName)
    }

    $resolved = New-Object System.Collections.Generic.List[string]
    $visiting = @{}
    $visited = @{}

    function Add-ResolvedComponent {
        param([string]$ComponentName)

        if ($visited.ContainsKey($ComponentName)) { return }
        if ($visiting.ContainsKey($ComponentName)) {
            throw "Ciclo de dependências detectado em: $ComponentName"
        }

        $componentDef = $components[$ComponentName]
        if (-not $componentDef) {
            throw "Componente desconhecido: $ComponentName"
        }

        $visiting[$ComponentName] = $true
        foreach ($dependency in $componentDef.DependsOn) {
            Add-ResolvedComponent -ComponentName $dependency
        }
        $visiting.Remove($ComponentName) | Out-Null
        $visited[$ComponentName] = $true

        if (-not $resolved.Contains($ComponentName)) {
            $resolved.Add($ComponentName)
        }
    }

    foreach ($componentName in $requested) {
        Add-ResolvedComponent -ComponentName $componentName
    }

    $normalizedExcludes = @(Normalize-BootstrapNames -Names $ExcludedComponents)
    foreach ($excludedName in $normalizedExcludes) {
        if (-not $components.Contains($excludedName)) {
            throw "Componente excluído desconhecido: $excludedName"
        }
        if (-not $resolved.Contains($excludedName)) { continue }

        if (-not $components[$excludedName].Optional) {
            throw "O componente $excludedName é obrigatório e não pode ser excluído."
        }

        foreach ($resolvedName in @($resolved.ToArray())) {
            if ($resolvedName -eq $excludedName) { continue }
            if (Test-BootstrapComponentDependsOn -ComponentName $resolvedName -DependencyName $excludedName -Catalog $components) {
                throw "Não é possível excluir $excludedName porque ele é dependência obrigatória de $resolvedName."
            }
        }

        $resolved.Remove($excludedName) | Out-Null
    }

    return [pscustomobject]@{
        ExpandedProfiles = @($expandedProfiles.ToArray())
        RequestedComponents = @($requested.ToArray())
        ExcludedComponents = @($normalizedExcludes)
        ResolvedComponents = @($resolved.ToArray())
    }
}

function Invoke-BootstrapInteractiveSelection {
    Write-Host 'Selecione um modo de execução:'
    Write-Host '1. Recommended'
    Write-Host '2. Legacy'
    Write-Host '3. Full'
    Write-Host '4. Custom by profile'
    Write-Host '5. Custom by component'

    $choice = (Read-Host 'Opção').Trim()
    switch ($choice) {
        '1' { $selectedProfiles = @('recommended'); $selectedComponents = @(); $selectedExcludes = @() }
        '2' { $selectedProfiles = @('legacy'); $selectedComponents = @(); $selectedExcludes = @() }
        '3' { $selectedProfiles = @('full'); $selectedComponents = @(); $selectedExcludes = @() }
        '4' {
            $profilesInput = Read-Host 'Perfis (separados por vírgula)'
            $excludeInput = Read-Host 'Exclusões opcionais (ou Enter para nenhuma)'
            $selectedProfiles = Normalize-BootstrapNames -Names @($profilesInput)
            $selectedComponents = @()
            $selectedExcludes = Normalize-BootstrapNames -Names @($excludeInput)
        }
        '5' {
            $componentsInput = Read-Host 'Componentes (separados por vírgula)'
            $excludeInput = Read-Host 'Exclusões opcionais (ou Enter para nenhuma)'
            $selectedProfiles = @()
            $selectedComponents = Normalize-BootstrapNames -Names @($componentsInput)
            $selectedExcludes = Normalize-BootstrapNames -Names @($excludeInput)
        }
        default {
            throw "Opção interativa inválida: $choice"
        }
    }

    Write-Host 'Selecione o modo HostHealth:'
    Write-Host '1. conservador (recomendado)'
    Write-Host '2. equilibrado'
    Write-Host '3. agressivo'
    Write-Host '4. off'
    $hostHealthChoice = (Read-Host 'HostHealth').Trim()
    $selectedHostHealth = switch ($hostHealthChoice) {
        '1' { 'conservador' }
        '2' { 'equilibrado' }
        '3' { 'agressivo' }
        '4' { 'off' }
        default { throw "Modo HostHealth interativo inválido: $hostHealthChoice" }
    }

    return [pscustomobject]@{
        Profiles = @($selectedProfiles)
        Components = @($selectedComponents)
        Excludes = @($selectedExcludes)
        HostHealth = $selectedHostHealth
    }
}

function Get-BootstrapSelection {
    $profiles = @(Normalize-BootstrapNames -Names $Profile)
    $components = @(Normalize-BootstrapNames -Names $Component)
    $excludes = @(Normalize-BootstrapNames -Names $Exclude)
    $selectedHostHealth = Normalize-BootstrapHostHealthMode -Mode $HostHealth

    if ($Interactive -and -not $NonInteractive -and $profiles.Count -eq 0 -and $components.Count -eq 0) {
        return Invoke-BootstrapInteractiveSelection
    }

    if ($profiles.Count -eq 0 -and $components.Count -eq 0) {
        $profiles = @('legacy')
    }

    return [pscustomobject]@{
        Profiles = $profiles
        Components = $components
        Excludes = $excludes
        HostHealth = $selectedHostHealth
    }
}

function Resolve-BootstrapCloneBaseDir {
    param(
        [string]$ExplicitCloneBaseDir,
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceRoot,
        [string[]]$ResolvedComponents
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitCloneBaseDir)) {
        return $ExplicitCloneBaseDir
    }

    $preferredProjectsDir = Join-Path $ResolvedWorkspaceRoot 'DevProjetos'
    $driveRoot = $null
    try { $driveRoot = Split-Path -Path $ResolvedWorkspaceRoot -Qualifier } catch { $driveRoot = $null }

    if (($ResolvedComponents -contains 'workspace-layout') -and $driveRoot -and (Test-Path $driveRoot)) {
        return $preferredProjectsDir
    }

    return (Get-Location).Path
}

function New-BootstrapState {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedCloneBaseDir,
        [string]$RequestedSteamDeckVersion = 'Auto',
        [string]$ResolvedSteamDeckVersion = 'lcd',
        [string]$HostHealthMode = 'off',
        [bool]$UsesSteamDeckFlow = $false,
        [bool]$IsDryRun = $false
    )

    return @{
        DryRun = $IsDryRun
        WorkspaceRoot = $ResolvedWorkspaceRoot
        CloneBaseDir = $ResolvedCloneBaseDir
        RequestedSteamDeckVersion = $RequestedSteamDeckVersion
        ResolvedSteamDeckVersion = $ResolvedSteamDeckVersion
        HostHealthMode = $HostHealthMode
        UsesSteamDeckFlow = $UsesSteamDeckFlow
        HostHealthReportRoot = $null
        SteamDeckSettingsPath = $null
        SteamDeckAutomationRoot = $null
        SteamDeckToolsRoot = $null
        Winget = $null
        GitInfo = $null
        NodeInfo = $null
        PythonReady = $false
        Completed = @{}
    }
}

function Ensure-BootstrapSystemCore {
    param([hashtable]$State)
    if ($State.Winget) { return }
    Ensure-ProxyEnvFromWinHttp
    $State.Winget = Ensure-Winget
    Refresh-SessionPath
}

function Ensure-BootstrapGitCore {
    param([hashtable]$State)
    if ($State.GitInfo) { return }
    Ensure-BootstrapSystemCore -State $State
    $State.GitInfo = Ensure-GitAndBash -WingetPath $State.Winget
    Refresh-SessionPath
}

function Ensure-BootstrapNodeCore {
    param([hashtable]$State)
    if ($State.NodeInfo) { return }
    Ensure-BootstrapSystemCore -State $State
    $State.NodeInfo = Ensure-NodeAndNpm -WingetPath $State.Winget
    Refresh-SessionPath
}

function Ensure-BootstrapPythonCore {
    param([hashtable]$State)
    if ($State.PythonReady) { return }
    Ensure-BootstrapSystemCore -State $State
    Ensure-Python -WingetPath $State.Winget
    $null = Ensure-Uv
    $State.PythonReady = $true
    Refresh-SessionPath
}

function Ensure-7ZipOnPath {
    $sevenZipDir = $null
    try { $sevenZipDir = Join-Path $env:ProgramFiles '7-Zip' } catch { $sevenZipDir = $null }
    if ($sevenZipDir -and (Test-Path $sevenZipDir)) {
        Ensure-PathUserContains -Dir $sevenZipDir
        Refresh-SessionPath
    }
}

function Ensure-GitLfs {
    param([hashtable]$State)
    Ensure-BootstrapGitCore -State $State
    Ensure-BootstrapSystemCore -State $State
    Ensure-WingetPackage -WingetPath $State.Winget -Id 'GitHub.GitLFS' -DisplayName 'Git LFS'
    $exitCode = Invoke-NativeWithLog -Exe $State.GitInfo.Git -Args @('lfs', 'install')
    if ($exitCode -ne 0) { throw "Falha ao executar git lfs install (exit=$exitCode)." }
}

function Ensure-WslCore {
    param([hashtable]$State)
    Ensure-BootstrapSystemCore -State $State

    if (-not (Test-IsAdmin)) {
        Write-Log 'WSL core requer privilégios de administrador para habilitar recursos do Windows. Pulando.' 'WARN'
        return
    }

    Ensure-WindowsOptionalFeatureEnabled -FeatureName 'Microsoft-Windows-Subsystem-Linux' -DisplayName 'Windows Subsystem for Linux'
    Ensure-WindowsOptionalFeatureEnabled -FeatureName 'VirtualMachinePlatform' -DisplayName 'Virtual Machine Platform'

    $wslExe = Resolve-CommandPath -Name 'wsl.exe'
    if (-not $wslExe) {
        $candidate = Join-Path $env:SystemRoot 'System32\wsl.exe'
        if (Test-Path $candidate) { $wslExe = $candidate }
    }
    if (-not $wslExe) {
        Write-Log 'wsl.exe não encontrado após habilitar os recursos do Windows.' 'WARN'
        return
    }

    $distros = ''
    try { $distros = (& $wslExe -l -q 2>&1 | Out-String) } catch { $distros = '' }
    if ($distros -notmatch '(?im)^ubuntu\s*$') {
        $installExitCode = Invoke-NativeWithLog -Exe $wslExe -Args @('--install', '-d', 'Ubuntu')
        if (($installExitCode -ne 0) -and ($installExitCode -ne 3010)) {
            Write-Log "Falha ao executar wsl --install -d Ubuntu (exit=$installExitCode)." 'WARN'
        }
    } else {
        Write-Log 'Ubuntu já está listado no WSL.'
    }

    $updateExitCode = Invoke-NativeWithLog -Exe $wslExe -Args @('--update')
    if (($updateExitCode -ne 0) -and ($updateExitCode -ne 3010)) {
        Write-Log "Falha ao executar wsl --update (exit=$updateExitCode)." 'WARN'
    }

    $defaultVersionExitCode = Invoke-NativeWithLog -Exe $wslExe -Args @('--set-default-version', '2')
    if (($defaultVersionExitCode -ne 0) -and ($defaultVersionExitCode -ne 3010)) {
        Write-Log "Falha ao executar wsl --set-default-version 2 (exit=$defaultVersionExitCode)." 'WARN'
    }
}

function Ensure-WorkspaceLayout {
    param([hashtable]$State)
    $workspaceRoot = $State.WorkspaceRoot
    $driveRoot = $null
    try { $driveRoot = Split-Path -Path $workspaceRoot -Qualifier } catch { $driveRoot = $null }
    if ($driveRoot -and (-not (Test-Path $driveRoot))) {
        Write-Log "Workspace root indisponível: $workspaceRoot. Mantendo CloneBaseDir atual: $($State.CloneBaseDir)" 'WARN'
        return
    }

    $paths = @(
        $workspaceRoot,
        (Join-Path $workspaceRoot 'DevKits'),
        (Join-Path $workspaceRoot 'DevProjetos'),
        (Join-Path (Join-Path $workspaceRoot 'DevProjetos') 'Docker')
    )

    foreach ($path in $paths) {
        $null = New-Item -Path $path -ItemType Directory -Force
        Write-Log "Workspace garantido: $path"
    }
}

function Ensure-BootstrapSteamDeckToolsRuntime {
    param([hashtable]$State)

    Ensure-BootstrapSystemCore -State $State

    $installRoot = if (Test-IsAdmin) {
        Join-Path $env:ProgramFiles 'SteamDeckTools'
    } else {
        Join-Path $env:LOCALAPPDATA 'Programs\SteamDeckTools'
    }

    $probePaths = @(
        (Join-Path $installRoot 'PowerControl.exe'),
        (Join-Path $installRoot 'SteamController.exe'),
        (Join-Path $installRoot 'PerformanceOverlay.exe')
    )

    foreach ($probePath in $probePaths) {
        if (Test-Path $probePath) {
            $State.SteamDeckToolsRoot = $installRoot
            Write-Log "Steam Deck Tools ja encontrado em $installRoot"
            return
        }
    }

    $downloadUrl = 'https://github.com/ayufan/steam-deck-tools/releases/download/0.7.3/SteamDeckTools-0.7.3-portable.zip'
    $zipPath = Join-Path $env:TEMP ("steamdecktools_{0}.zip" -f ([Guid]::NewGuid().ToString('N')))
    $extractDir = Join-Path $env:TEMP ("steamdecktools_extract_{0}" -f ([Guid]::NewGuid().ToString('N')))

    try {
        Write-Log "Baixando Steam Deck Tools portable: $downloadUrl"
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $zipPath | Out-Null
        $null = New-Item -Path $extractDir -ItemType Directory -Force
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        $null = New-Item -Path $installRoot -ItemType Directory -Force
        Copy-Item -Path (Join-Path $extractDir '*') -Destination $installRoot -Recurse -Force
    } finally {
        if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $finalProbe = Join-Path $installRoot 'PowerControl.exe'
    if (-not (Test-Path $finalProbe)) {
        throw "Steam Deck Tools baixado, mas PowerControl.exe nao foi encontrado em $installRoot."
    }

    $State.SteamDeckToolsRoot = $installRoot
    Write-Log "Steam Deck Tools instalado em $installRoot"
}

function Write-BootstrapJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }

    (ConvertTo-BootstrapObjectGraph -InputObject $Value) | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding utf8
}

function Write-BootstrapExecutionResultFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    Write-BootstrapJsonFile -Path $Path -Value $Value
}

function Ensure-BootstrapRegistryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        $null = New-Item -Path $Path -Force
    }
}

function Set-BootstrapRegistryDword {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )

    Ensure-BootstrapRegistryPath -Path $Path
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Get-BootstrapHostHealthReportRoot {
    param([hashtable]$State)

    if (-not $State.HostHealthReportRoot) {
        $State.HostHealthReportRoot = Get-BootstrapHostHealthRoot
    }

    $null = New-Item -Path $State.HostHealthReportRoot -ItemType Directory -Force
    return $State.HostHealthReportRoot
}

function Export-BootstrapHostHealthSnapshots {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$Policy
    )

    $reportRoot = Get-BootstrapHostHealthReportRoot -State $State

    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object Name, Command, Location, User)
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Select-Object TaskPath, TaskName, State)
    $services = @(Get-Service -ErrorAction SilentlyContinue | Select-Object Name, DisplayName, StartType, Status)
    $appx = @(Get-AppxPackage -ErrorAction SilentlyContinue | Select-Object Name, PackageFullName)

    Write-BootstrapJsonFile -Path (Join-Path $reportRoot 'snapshot-startup.json') -Value $startup
    Write-BootstrapJsonFile -Path (Join-Path $reportRoot 'snapshot-tasks.json') -Value $tasks
    Write-BootstrapJsonFile -Path (Join-Path $reportRoot 'snapshot-services.json') -Value $services
    Write-BootstrapJsonFile -Path (Join-Path $reportRoot 'snapshot-appx.json') -Value $appx
    Write-BootstrapJsonFile -Path (Join-Path $reportRoot 'policy.json') -Value $Policy
}

function Clear-BootstrapDirectoryContents {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    if (-not (Test-Path $TargetPath)) { return }

    foreach ($item in @(Get-ChildItem -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue)) {
        try {
            if ($item.PSIsContainer) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
            }
        } catch {
            Write-Log "Nao foi possivel remover $($item.FullName). Pulando item em uso ou protegido." 'WARN'
        }
    }
}

function Invoke-BootstrapHostHealthCleanup {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$Policy
    )

    $targets = @(
        $env:TEMP,
        (Join-Path $env:LOCALAPPDATA 'Temp')
    )

    if (Test-IsAdmin) {
        $targets += @('C:\Windows\Temp')
    }

    foreach ($target in $targets) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        Write-Log "HostHealth cleanup: limpando $target"
        Clear-BootstrapDirectoryContents -TargetPath $target
    }

    $bootstrapTempFiles = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'bootstrap-tools_*' -Force -ErrorAction SilentlyContinue)
    foreach ($file in $bootstrapTempFiles) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        } catch {
            Write-Log "Nao foi possivel remover residuo do bootstrap: $($file.FullName)" 'WARN'
        }
    }

    if (Test-IsAdmin) {
        $dismExe = Join-Path $env:SystemRoot 'System32\dism.exe'
        if (Test-Path $dismExe) {
            $exitCode = Invoke-NativeWithLog -Exe $dismExe -Args @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
            if (($exitCode -ne 0) -and ($exitCode -ne 3010)) {
                Write-Log "HostHealth cleanup: DISM StartComponentCleanup falhou (exit=$exitCode)." 'WARN'
            }
        }

        $windowsOld = 'C:\Windows.old'
        if (Test-Path $windowsOld) {
            $resolvedWindowsOld = (Get-Item -LiteralPath $windowsOld -ErrorAction SilentlyContinue).FullName
            if ($resolvedWindowsOld -eq $windowsOld) {
                try {
                    Remove-Item -LiteralPath $windowsOld -Recurse -Force -ErrorAction Stop
                    Write-Log 'HostHealth cleanup: Windows.old removido.'
                } catch {
                    Write-Log 'HostHealth cleanup: nao foi possivel remover C:\Windows.old.' 'WARN'
                }
            }
        }
    } else {
        Write-Log 'HostHealth cleanup: DISM e remocao de Windows.old requerem elevacao. Pulando.' 'WARN'
    }
}

function Disable-BootstrapRunEntries {
    param([string[]]$Patterns)

    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path $runPath)) { return }

    $item = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue
    if (-not $item) { return }

    foreach ($property in @($item.PSObject.Properties)) {
        if ($property.Name -like 'PS*') { continue }
        foreach ($pattern in @($Patterns)) {
            if ($property.Name -like $pattern) {
                try {
                    Remove-ItemProperty -Path $runPath -Name $property.Name -ErrorAction Stop
                    Write-Log "HostHealth startup: entrada Run removida -> $($property.Name)"
                } catch {
                    Write-Log "HostHealth startup: falha ao remover Run $($property.Name)." 'WARN'
                }
                break
            }
        }
    }
}

function Disable-BootstrapScheduledTasks {
    param($TaskDefinitions)

    foreach ($taskDefinition in @($TaskDefinitions)) {
        if (-not $taskDefinition) { continue }
        try {
            $task = Get-ScheduledTask -TaskPath $taskDefinition.TaskPath -TaskName $taskDefinition.TaskName -ErrorAction Stop
            Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
            Write-Log "HostHealth startup: tarefa desabilitada -> $($taskDefinition.TaskPath)$($taskDefinition.TaskName)"
        } catch {
            Write-Log "HostHealth startup: tarefa nao alterada -> $($taskDefinition.TaskPath)$($taskDefinition.TaskName)" 'WARN'
        }
    }
}

function Set-BootstrapServiceStartupTypes {
    param($ServiceAdjustments)

    foreach ($adjustment in @($ServiceAdjustments)) {
        if (-not $adjustment) { continue }
        try {
            Set-Service -Name $adjustment.Name -StartupType $adjustment.StartType -ErrorAction Stop
            Write-Log "HostHealth startup: servico ajustado -> $($adjustment.Name) => $($adjustment.StartType)"
        } catch {
            Write-Log "HostHealth startup: servico nao alterado -> $($adjustment.Name)" 'WARN'
        }
    }
}

function Invoke-BootstrapHostHealthStartup {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$Policy
    )

    Disable-BootstrapRunEntries -Patterns @(
        'MicrosoftEdgeAutoLaunch_*',
        'Teams',
        'GoogleChromeAutoLaunch_*',
        'Outlook*',
        '*DevHome*',
        '*PCManager*'
    )

    if ($Policy.Mode -in @('equilibrado', 'agressivo')) {
        Disable-BootstrapScheduledTasks -TaskDefinitions $Policy.ScheduledTasksDisable
    }

    if ($Policy.Mode -eq 'agressivo') {
        if (Test-IsAdmin) {
            Set-BootstrapServiceStartupTypes -ServiceAdjustments $Policy.ServiceAdjustments
        } else {
            Write-Log 'HostHealth startup: ajustes de servico requerem elevacao. Pulando.' 'WARN'
        }
    }
}

function Invoke-BootstrapHostHealthRegistryFixes {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$Policy
    )

    $contentPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($valueName in @(
        'SilentInstalledAppsEnabled',
        'SubscribedContent-338388Enabled',
        'SubscribedContent-338389Enabled',
        'SubscribedContent-353698Enabled',
        'SystemPaneSuggestionsEnabled'
    )) {
        Set-BootstrapRegistryDword -Path $contentPath -Name $valueName -Value 0
    }

    $edgePolicyPath = 'HKCU:\Software\Policies\Microsoft\Edge'
    Set-BootstrapRegistryDword -Path $edgePolicyPath -Name 'StartupBoostEnabled' -Value 0
    Set-BootstrapRegistryDword -Path $edgePolicyPath -Name 'BackgroundModeEnabled' -Value 0

    $explorerAdvancedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-BootstrapRegistryDword -Path $explorerAdvancedPath -Name 'TaskbarDa' -Value 0

    $gameBarPath = 'HKCU:\Software\Microsoft\GameBar'
    Set-BootstrapRegistryDword -Path $gameBarPath -Name 'AutoGameModeEnabled' -Value 1
}

function Sync-BootstrapSteamDeckHostHealthSettings {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$Policy
    )

    $settingsPath = Ensure-BootstrapSteamDeckSettings -State $State
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $settingsData = Normalize-BootstrapSteamDeckSettingsData -Settings $settings
    $settingsData['sessionProfiles'] = ConvertTo-BootstrapHashtable -InputObject $Policy.SessionProfiles
    $settingsData['hostHealth'] = @{
        mode = $Policy.Mode
        killInGame = @($Policy.KillInGame)
        keepAlways = @($Policy.KeepAlways)
    }
    Write-BootstrapJsonFile -Path $settingsPath -Value $settingsData
    $State.SteamDeckSettingsPath = $settingsPath
}

function Invoke-BootstrapHostHealthGameMode {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$Policy
    )

    if ($State.UsesSteamDeckFlow) {
        Sync-BootstrapSteamDeckHostHealthSettings -State $State -Policy $Policy
        Write-Log "HostHealth game-mode: session profiles atualizados para o watcher do Steam Deck ($($Policy.Mode))."
    } else {
        Write-Log 'HostHealth game-mode: nenhum watcher Steam Deck ativo neste fluxo; somente politica do host foi registrada.'
    }
}

function Invoke-BootstrapHostHealthBloat {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$Policy
    )

    foreach ($packageName in @($Policy.AppxRemove)) {
        try {
            $packages = @(Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue)
            if ($packages.Count -eq 0) {
                Write-Log "HostHealth bloat: pacote nao presente -> $packageName"
                continue
            }

            foreach ($package in $packages) {
                Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
                Write-Log "HostHealth bloat: pacote removido do usuario atual -> $packageName"
            }
        } catch {
            Write-Log "HostHealth bloat: falha ao remover $packageName do usuario atual." 'WARN'
        }
    }
}

function Invoke-BootstrapHostHealthVerify {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)]$Policy
    )

    $reportRoot = Get-BootstrapHostHealthReportRoot -State $State
    $summary = [ordered]@{
        mode = $Policy.Mode
        reportRoot = $reportRoot
        generatedAt = (Get-Date).ToString('o')
        host = $env:COMPUTERNAME
        user = $env:USERNAME
        usesSteamDeckFlow = $State.UsesSteamDeckFlow
    }
    Write-BootstrapJsonFile -Path (Join-Path $reportRoot 'summary.json') -Value $summary
}

function Invoke-BootstrapHostHealth {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    $normalizedMode = Normalize-BootstrapHostHealthMode -Mode $Mode
    if ($normalizedMode -eq 'off') {
        Write-Log 'HostHealth: desligado para esta execucao.'
        return
    }

    $policy = Get-BootstrapHostHealthPolicy -Mode $normalizedMode
    Export-BootstrapHostHealthSnapshots -State $State -Policy $policy
    Invoke-BootstrapHostHealthCleanup -State $State -Policy $policy
    Invoke-BootstrapHostHealthStartup -State $State -Policy $policy
    Invoke-BootstrapHostHealthRegistryFixes -State $State -Policy $policy
    Invoke-BootstrapHostHealthGameMode -State $State -Policy $policy
    Invoke-BootstrapHostHealthBloat -State $State -Policy $policy
    Invoke-BootstrapHostHealthVerify -State $State -Policy $policy
}

function Invoke-BootstrapComponent {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    if ($State.Completed.ContainsKey($Name)) { return }

    $catalog = Get-BootstrapComponentCatalog
    $componentDef = $catalog[$Name]
    if (-not $componentDef) { throw "Componente desconhecido: $Name" }

    Write-Log "Executando componente: $Name"

    switch ($componentDef.Kind) {
        'alias' { }
        'system-core' { Ensure-BootstrapSystemCore -State $State }
        'git-core' { Ensure-BootstrapGitCore -State $State }
        'node-core' { Ensure-BootstrapNodeCore -State $State }
        'python-core' { Ensure-BootstrapPythonCore -State $State }
        'sevenzip' {
            Ensure-BootstrapSystemCore -State $State
            Ensure-WingetPackage -WingetPath $State.Winget -Id '7zip.7zip' -DisplayName '7-Zip' -AllowFailureWhenNotAdmin $true
            Ensure-7ZipOnPath
        }
        'winget' {
            Ensure-BootstrapSystemCore -State $State
            $preferUserScope = $true
            if ($componentDef.PSObject.Properties.Name -contains 'PreferUserScope') { $preferUserScope = [bool]$componentDef.PreferUserScope }
            $allowFailureWhenNotAdmin = $false
            if ($componentDef.PSObject.Properties.Name -contains 'AllowFailureWhenNotAdmin') { $allowFailureWhenNotAdmin = [bool]$componentDef.AllowFailureWhenNotAdmin }
            Ensure-WingetPackage -WingetPath $State.Winget -Id $componentDef.Id -DisplayName $componentDef.DisplayName -PreferUserScope $preferUserScope -AllowFailureWhenNotAdmin $allowFailureWhenNotAdmin
        }
        'git-lfs' {
            Ensure-GitLfs -State $State
        }
        'wsl-core' {
            Ensure-WslCore -State $State
        }
        'wsl-ui' {
            Ensure-BootstrapSystemCore -State $State
            Ensure-WslUi -WingetPath $State.Winget
        }
        'claude-code' {
            Ensure-BootstrapSystemCore -State $State
            Ensure-ClaudeCode -WingetPath $State.Winget
        }
        'codex-installer' {
            Ensure-BootstrapSystemCore -State $State
            Ensure-CodexInstaller -WingetPath $State.Winget
        }
        'npm' {
            Ensure-BootstrapNodeCore -State $State
            Ensure-NpmGlobalPackage -NpmCmd $State.NodeInfo.NpmCmd -Package $componentDef.Package -DisplayName $componentDef.DisplayName
        }
        'uvtool' {
            Ensure-BootstrapPythonCore -State $State
            Ensure-UvToolPackage -Package $componentDef.Package -CommandName $componentDef.CommandName -DisplayName $componentDef.DisplayName -VersionArgs $componentDef.VersionArgs
        }
        'goose' {
            Ensure-BootstrapGitCore -State $State
            Ensure-Goose -BashPath $State.GitInfo.Bash
        }
        'opencode' {
            Ensure-BootstrapGitCore -State $State
            Ensure-OpenCode -BashPath $State.GitInfo.Bash
        }
        'openclaw' {
            Ensure-BootstrapNodeCore -State $State
            Ensure-OpenClaw -NpmCmd $State.NodeInfo.NpmCmd
        }
        'claude-config' {
            Ensure-BootstrapGitCore -State $State
            Ensure-ClaudeCodeDefaults -GitBashPath $State.GitInfo.Bash
            Ensure-ClaudeHookConfigsHealthy -GitBashPath $State.GitInfo.Bash
        }
        'repo-clone' {
            Ensure-BootstrapGitCore -State $State
            $targetDir = Join-Path $State.CloneBaseDir $componentDef.TargetName
            Ensure-RepoClone -GitExe $State.GitInfo.Git -RepoUrl $componentDef.RepoUrl -TargetDir $targetDir
        }
        'workspace' {
            Ensure-WorkspaceLayout -State $State
        }
        'steamdeck-tools' {
            Ensure-BootstrapSteamDeckToolsRuntime -State $State
        }
        'steamdeck-settings' {
            Ensure-BootstrapSteamDeckSettings -State $State | Out-Null
        }
        'steamdeck-automation' {
            Ensure-BootstrapSteamDeckAutomation -State $State
        }
        'manual-required' {
            Ensure-BootstrapManualRequirement -State $State -ComponentDef $componentDef
        }
        default {
            throw "Tipo de componente não suportado: $($componentDef.Kind)"
        }
    }

    Refresh-SessionPath
    $State.Completed[$Name] = $true
}

function Get-BootstrapExecutionPlanLines {
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)]$Resolution,
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedCloneBaseDir,
        [string]$ResolvedSteamDeckVersion = '',
        [Parameter(Mandatory = $true)][string]$ResolvedHostHealthMode
    )

    $catalog = Get-BootstrapComponentCatalog
    $usesSteamDeckFlow = Get-BootstrapUsesSteamDeckFlow -Selection $Selection -Resolution $Resolution
    $lines = New-Object System.Collections.Generic.List[string]
    $stageLookup = [ordered]@{
        runtime = New-Object System.Collections.Generic.List[string]
        payload = New-Object System.Collections.Generic.List[string]
        config = New-Object System.Collections.Generic.List[string]
        verify = New-Object System.Collections.Generic.List[string]
    }
    $manualBlockers = New-Object System.Collections.Generic.List[string]

    foreach ($componentName in @($Resolution.ResolvedComponents)) {
        $componentDef = $catalog[$componentName]
        if (-not $componentDef) { continue }
        $stage = Get-BootstrapComponentStage -ComponentDef $componentDef
        if (-not $stageLookup.Contains($stage)) {
            $stageLookup[$stage] = New-Object System.Collections.Generic.List[string]
        }
        $stageLookup[$stage].Add($componentName)
        if ($componentDef.Kind -eq 'manual-required') {
            $manualBlockers.Add($componentName)
        }
    }

    $lines.Add(('Selected profiles: {0}' -f ($(if (@($Selection.Profiles).Count -gt 0) { @($Selection.Profiles) -join ', ' } else { '-' }))))
    $lines.Add(('Selected components: {0}' -f ($(if (@($Selection.Components).Count -gt 0) { @($Selection.Components) -join ', ' } else { '-' }))))
    $lines.Add(('Excluded components: {0}' -f ($(if (@($Selection.Excludes).Count -gt 0) { @($Selection.Excludes) -join ', ' } else { '-' }))))
    $lines.Add(('Expanded profiles: {0}' -f ($(if (@($Resolution.ExpandedProfiles).Count -gt 0) { @($Resolution.ExpandedProfiles) -join ', ' } else { '-' }))))
    $lines.Add(('Resolved components: {0}' -f ($(if (@($Resolution.ResolvedComponents).Count -gt 0) { @($Resolution.ResolvedComponents) -join ', ' } else { '-' }))))
    $lines.Add(('WorkspaceRoot: {0}' -f $ResolvedWorkspaceRoot))
    $lines.Add(('CloneBaseDir: {0}' -f $ResolvedCloneBaseDir))
    $lines.Add(('Host health mode: {0}' -f $ResolvedHostHealthMode))

    if ($usesSteamDeckFlow) {
        $lines.Add(('Resolved steam deck version: {0}' -f $ResolvedSteamDeckVersion))
    }

    if ($usesSteamDeckFlow) {
        $lines.Add('Audit:')
        foreach ($componentName in @($Resolution.ResolvedComponents)) {
            $componentDef = $catalog[$componentName]
            if (-not $componentDef) { continue }
            $stage = Get-BootstrapComponentStage -ComponentDef $componentDef
            $dependsOn = if (@($componentDef.DependsOn).Count -gt 0) { @($componentDef.DependsOn) -join ', ' } else { '-' }
            $valueReason = if ($componentDef.PSObject.Properties.Name -contains 'ValueReason') { [string]$componentDef.ValueReason } else { [string]$componentDef.Description }
            $provisioning = if ($componentDef.PSObject.Properties.Name -contains 'Provisioning') { [string]$componentDef.Provisioning } else { $componentDef.Kind }
            $lines.Add(('  - {0} | stage: {1} | depends: {2} | provisioning: {3} | gain: {4}' -f $componentName, $stage, $dependsOn, $provisioning, $valueReason))
        }

        $lines.Add(('Runtimes: {0}' -f ($(if ($stageLookup['runtime'].Count -gt 0) { @($stageLookup['runtime'].ToArray()) -join ', ' } else { '-' }))))
        $lines.Add(('Payloads: {0}' -f ($(if ($stageLookup['payload'].Count -gt 0) { @($stageLookup['payload'].ToArray()) -join ', ' } else { '-' }))))
        $lines.Add(('Config: {0}' -f ($(if ($stageLookup['config'].Count -gt 0) { @($stageLookup['config'].ToArray()) -join ', ' } else { '-' }))))
        $lines.Add(('Verify: {0}' -f ($(if ($stageLookup['verify'].Count -gt 0) { @($stageLookup['verify'].ToArray()) -join ', ' } else { '-' }))))
        $lines.Add(('Manual blockers: {0}' -f ($(if ($manualBlockers.Count -gt 0) { @($manualBlockers.ToArray()) -join ', ' } else { '-' }))))
    }

    if ($ResolvedHostHealthMode -ne 'off') {
        $policy = Get-BootstrapHostHealthPolicy -Mode $ResolvedHostHealthMode
        $lines.Add(('Host health cleanup: {0}' -f (@($policy.Cleanup) -join ', ')))
        $lines.Add(('Host health startup: {0}' -f ((@($policy.StartupDisableSafe) + @($policy.ScheduledTasksDisable | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }) + @($policy.ServiceAdjustments | ForEach-Object { "$($_.Name)=$($_.StartType)" })) -join ', ')))
        $lines.Add(('Host health registry-fixes: {0}' -f (@($policy.RegistryFixes) -join ', ')))
        $lines.Add(('Host health game-mode: HANDHELD={0}, DOCKED_TV={1}, DOCKED_MONITOR={2}' -f $policy.SessionProfiles.HANDHELD, $policy.SessionProfiles.DOCKED_TV, $policy.SessionProfiles.DOCKED_MONITOR))
        $lines.Add(('Host health bloat: {0}' -f ($(if (@($policy.AppxRemove).Count -gt 0) { @($policy.AppxRemove) -join ', ' } else { '-' }))))
        $lines.Add(('Host health verify: {0}' -f (@($policy.Verify) -join ', ')))
    }

    return @($lines.ToArray())
}

function Get-BootstrapExecutionPlanText {
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)]$Resolution,
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedCloneBaseDir,
        [string]$ResolvedSteamDeckVersion = '',
        [Parameter(Mandatory = $true)][string]$ResolvedHostHealthMode
    )

    return ((Get-BootstrapExecutionPlanLines -Selection $Selection -Resolution $Resolution -ResolvedWorkspaceRoot $ResolvedWorkspaceRoot -ResolvedCloneBaseDir $ResolvedCloneBaseDir -ResolvedSteamDeckVersion $ResolvedSteamDeckVersion -ResolvedHostHealthMode $ResolvedHostHealthMode) -join [Environment]::NewLine)
}

function Show-BootstrapExecutionPlan {
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)]$Resolution,
        [Parameter(Mandatory = $true)][string]$ResolvedWorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedCloneBaseDir,
        [string]$ResolvedSteamDeckVersion = '',
        [Parameter(Mandatory = $true)][string]$ResolvedHostHealthMode
    )

    foreach ($line in (Get-BootstrapExecutionPlanLines -Selection $Selection -Resolution $Resolution -ResolvedWorkspaceRoot $ResolvedWorkspaceRoot -ResolvedCloneBaseDir $ResolvedCloneBaseDir -ResolvedSteamDeckVersion $ResolvedSteamDeckVersion -ResolvedHostHealthMode $ResolvedHostHealthMode)) {
        Write-Output $line
    }
}

function Get-BootstrapPreviewData {
    param(
        [string[]]$SelectedProfiles = @(),
        [string[]]$SelectedComponents = @(),
        [string[]]$ExcludedComponents = @(),
        [string]$RequestedSteamDeckVersion = 'Auto',
        [AllowNull()][string]$RequestedHostHealthMode = $null,
        [string]$RequestedWorkspaceRoot = 'F:\Steam\Steamapps',
        [string]$ExplicitCloneBaseDir = ''
    )

    $selection = New-BootstrapSelectionObject -SelectedProfiles $SelectedProfiles -SelectedComponents $SelectedComponents -ExcludedComponents $ExcludedComponents -SelectedHostHealth $RequestedHostHealthMode
    $resolvedWorkspaceRoot = if ([string]::IsNullOrWhiteSpace($RequestedWorkspaceRoot)) { 'F:\Steam\Steamapps' } else { $RequestedWorkspaceRoot }
    $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents $selection.Excludes
    $resolvedCloneBaseDir = Resolve-BootstrapCloneBaseDir -ExplicitCloneBaseDir $ExplicitCloneBaseDir -ResolvedWorkspaceRoot $resolvedWorkspaceRoot -ResolvedComponents $resolution.ResolvedComponents
    $usesSteamDeckFlow = Get-BootstrapUsesSteamDeckFlow -Selection $selection -Resolution $resolution
    $resolvedSteamDeckVersion = if ($usesSteamDeckFlow) { Get-BootstrapResolvedSteamDeckVersion -RequestedVersion $RequestedSteamDeckVersion } else { '' }
    $resolvedHostHealthMode = if ($selection.HostHealth) { $selection.HostHealth } else { Get-BootstrapDefaultHostHealthMode -Selection $selection -Resolution $resolution }
    $adminReasons = Get-BootstrapAdminReasons -Resolution $resolution -ResolvedHostHealthMode $resolvedHostHealthMode -UsesSteamDeckFlow:$usesSteamDeckFlow
    $planLines = Get-BootstrapExecutionPlanLines -Selection $selection -Resolution $resolution -ResolvedWorkspaceRoot $resolvedWorkspaceRoot -ResolvedCloneBaseDir $resolvedCloneBaseDir -ResolvedSteamDeckVersion $resolvedSteamDeckVersion -ResolvedHostHealthMode $resolvedHostHealthMode

    return [ordered]@{
        Selection = $selection
        Resolution = $resolution
        UsesSteamDeckFlow = $usesSteamDeckFlow
        ResolvedSteamDeckVersion = $resolvedSteamDeckVersion
        ResolvedHostHealthMode = $resolvedHostHealthMode
        ResolvedWorkspaceRoot = $resolvedWorkspaceRoot
        ResolvedCloneBaseDir = $resolvedCloneBaseDir
        AdminReasons = @($adminReasons)
        PlanLines = @($planLines)
        PlanText = ($planLines -join [Environment]::NewLine)
    }
}

function Write-BootstrapCommandSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string[]]$Args = @('--version')
    )

    $commandPath = Resolve-CommandPath -Name $CommandName
    if (-not $commandPath) {
        Write-Log ("{0}: NAO ENCONTRADO" -f $Label) 'WARN'
        return
    }

    Write-Log ("{0}: {1} ({2})" -f $Label, (Invoke-NativeFirstLine -Exe $commandPath -Args $Args), $commandPath)
}

function Invoke-BootstrapProfileMode {
    if ($Interactive -and $NonInteractive) {
        throw 'Use apenas um modo de entrada: -Interactive ou -NonInteractive.'
    }

    if ($ListProfiles) {
        Show-BootstrapProfiles
        return
    }

    if ($ListHostHealthModes) {
        Show-BootstrapHostHealthModes
        return
    }

    if ($ListComponents) {
        Show-BootstrapComponents
        return
    }

    $resolvedWorkspaceRoot = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        'F:\Steam\Steamapps'
    } else {
        $WorkspaceRoot
    }

    $selection = Get-BootstrapSelection
    $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents $selection.Excludes
    $resolvedCloneBaseDir = Resolve-BootstrapCloneBaseDir -ExplicitCloneBaseDir $CloneBaseDir -ResolvedWorkspaceRoot $resolvedWorkspaceRoot -ResolvedComponents $resolution.ResolvedComponents
    $usesSteamDeckFlow = Get-BootstrapUsesSteamDeckFlow -Selection $selection -Resolution $resolution
    $resolvedSteamDeckVersion = if ($usesSteamDeckFlow) { Get-BootstrapResolvedSteamDeckVersion -RequestedVersion $SteamDeckVersion } else { '' }
    $resolvedHostHealthMode = if ($selection.HostHealth) { $selection.HostHealth } else { Get-BootstrapDefaultHostHealthMode -Selection $selection -Resolution $resolution }

    Write-Log ("Inicio: {0}" -f $script:StartTime.ToString('s'))
    Write-Log "Log: $script:LogPath"
    Write-Log "Admin: $(Test-IsAdmin)"
    Write-Log ("Profiles selecionados: {0}" -f ($(if (@($selection.Profiles).Count -gt 0) { @($selection.Profiles) -join ', ' } else { '-' })))
    Write-Log ("Componentes selecionados: {0}" -f ($(if (@($selection.Components).Count -gt 0) { @($selection.Components) -join ', ' } else { '-' })))
    Write-Log ("Exclusoes: {0}" -f ($(if (@($selection.Excludes).Count -gt 0) { @($selection.Excludes) -join ', ' } else { '-' })))
    Write-Log ("Perfis expandidos: {0}" -f ($(if (@($resolution.ExpandedProfiles).Count -gt 0) { @($resolution.ExpandedProfiles) -join ', ' } else { '-' })))
    Write-Log ("Componentes resolvidos: {0}" -f ($(if (@($resolution.ResolvedComponents).Count -gt 0) { @($resolution.ResolvedComponents) -join ', ' } else { '-' })))
    Write-Log "WorkspaceRoot: $resolvedWorkspaceRoot"
    Write-Log "CloneBaseDir: $resolvedCloneBaseDir"
    Write-Log "HostHealth: $resolvedHostHealthMode"
    if ($usesSteamDeckFlow) {
        Write-Log "Steam Deck version resolvida: $resolvedSteamDeckVersion"
    }

    if ($DryRun) {
        Show-BootstrapExecutionPlan -Selection $selection -Resolution $resolution -ResolvedWorkspaceRoot $resolvedWorkspaceRoot -ResolvedCloneBaseDir $resolvedCloneBaseDir -ResolvedSteamDeckVersion $resolvedSteamDeckVersion -ResolvedHostHealthMode $resolvedHostHealthMode
        return
    }

    $state = New-BootstrapState -ResolvedWorkspaceRoot $resolvedWorkspaceRoot -ResolvedCloneBaseDir $resolvedCloneBaseDir -RequestedSteamDeckVersion $SteamDeckVersion -ResolvedSteamDeckVersion $resolvedSteamDeckVersion -HostHealthMode $resolvedHostHealthMode -UsesSteamDeckFlow:$usesSteamDeckFlow -IsDryRun:$DryRun

    foreach ($componentName in $resolution.ResolvedComponents) {
        Invoke-BootstrapComponent -Name $componentName -State $state
    }

    Invoke-BootstrapHostHealth -State $state -Mode $resolvedHostHealthMode

    if (-not [string]::IsNullOrWhiteSpace($script:ResultPath)) {
        Write-BootstrapExecutionResultFile -Path $script:ResultPath -Value ([ordered]@{
            status = 'success'
            generatedAt = (Get-Date).ToString('o')
            logPath = $script:LogPath
            resultPath = $script:ResultPath
            workspaceRoot = $resolvedWorkspaceRoot
            cloneBaseDir = $resolvedCloneBaseDir
            usesSteamDeckFlow = $usesSteamDeckFlow
            resolvedSteamDeckVersion = $resolvedSteamDeckVersion
            resolvedHostHealthMode = $resolvedHostHealthMode
            selection = $selection
            resolution = $resolution
            hostHealthReportRoot = $state.HostHealthReportRoot
            steamDeckSettingsPath = $state.SteamDeckSettingsPath
            steamDeckAutomationRoot = $state.SteamDeckAutomationRoot
        })
    }

    Write-Log 'Resumo:'
    Write-Log "CLAUDE_CODE_GIT_BASH_PATH: $([Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH','User'))"
    Write-BootstrapCommandSummary -Label 'git' -CommandName 'git' -Args @('--version')
    Write-BootstrapCommandSummary -Label 'node' -CommandName 'node' -Args @('-v')
    Write-BootstrapCommandSummary -Label 'npm' -CommandName 'npm' -Args @('--version')
    Write-BootstrapCommandSummary -Label 'java' -CommandName 'java' -Args @('-version')
    Write-BootstrapCommandSummary -Label 'magick' -CommandName 'magick' -Args @('-version')
    Write-BootstrapCommandSummary -Label '7z' -CommandName '7z' -Args @()
    Write-BootstrapCommandSummary -Label 'python' -CommandName 'python' -Args @('--version')
    Write-BootstrapCommandSummary -Label 'pip' -CommandName 'pip' -Args @('--version')
    Write-BootstrapCommandSummary -Label 'claude' -CommandName 'claude' -Args @('--version')
    Write-BootstrapCommandSummary -Label 'gh' -CommandName 'gh' -Args @('--version')
    Write-BootstrapCommandSummary -Label 'aider' -CommandName 'aider' -Args @('--version')
    Write-BootstrapCommandSummary -Label 'goose' -CommandName 'goose' -Args @('--version')
    Write-BootstrapCommandSummary -Label 'wsl' -CommandName 'wsl.exe' -Args @('--version')

    $opencodeExe = Join-Path (Join-Path $env:USERPROFILE '.opencode\bin') 'opencode.exe'
    if (Test-Path $opencodeExe) {
        Write-Log "opencode: $(& $opencodeExe --version) ($opencodeExe)"
    } else {
        Write-Log "opencode: NAO ENCONTRADO ($opencodeExe)" 'WARN'
    }

    if ($state.NodeInfo) {
        foreach ($tool in @(
            @{ Name = 'gemini'; Path = (Join-Path $state.NodeInfo.NpmBin 'gemini.cmd') },
            @{ Name = 'bonsai'; Path = (Join-Path $state.NodeInfo.NpmBin 'bonsai.cmd') },
            @{ Name = 'grok'; Path = (Join-Path $state.NodeInfo.NpmBin 'grok.cmd') },
            @{ Name = 'qwen'; Path = (Join-Path $state.NodeInfo.NpmBin 'qwen.cmd') },
            @{ Name = 'copilot'; Path = (Join-Path $state.NodeInfo.NpmBin 'copilot.cmd') },
            @{ Name = 'codex'; Path = (Join-Path $state.NodeInfo.NpmBin 'codex.cmd') },
            @{ Name = 'openclaw'; Path = (Join-Path $state.NodeInfo.NpmBin 'openclaw.cmd') }
        )) {
            if (Test-Path $tool.Path) {
                $version = Invoke-NativeFirstLine -Exe $tool.Path -Args @('--version')
                if ([string]::IsNullOrWhiteSpace($version)) { $version = 'instalado' }
                Write-Log ("{0}: {1} ({2})" -f $tool.Name, $version, $tool.Path)
            } else {
                Write-Log ("{0}: NAO ENCONTRADO ({1})" -f $tool.Name, $tool.Path) 'WARN'
            }
        }
    }

    $repoDir = Join-Path $resolvedCloneBaseDir 'gemini-cli'
    Write-Log "repo gemini-cli: $repoDir (exists=$(Test-Path $repoDir))"

    $elapsed = New-TimeSpan -Start $script:StartTime -End (Get-Date)
    Write-Log ("Concluido em {0:c}" -f $elapsed)
    Write-Log "Log salvo em: $script:LogPath"
}

$useBootstrapProfileMode = (
    $UiContractJson -or
    $ListProfiles -or
    $ListHostHealthModes -or
    $ListComponents -or
    $DryRun -or
    $Interactive -or
    $NonInteractive -or
    [string]::IsNullOrWhiteSpace($HostHealth) -eq $false -or
    (@($Profile).Count -gt 0) -or
    (@($Component).Count -gt 0) -or
    (@($Exclude).Count -gt 0)
)

if ($UiContractJson) {
    (Get-BootstrapUiContract | ConvertTo-Json -Depth 12)
    return
}

if ($BootstrapUiLibraryMode) {
    return
}

if ($useBootstrapProfileMode) {
    try {
        Invoke-BootstrapProfileMode
        exit 0
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($script:ResultPath)) {
            Write-BootstrapExecutionResultFile -Path $script:ResultPath -Value ([ordered]@{
                status = 'error'
                generatedAt = (Get-Date).ToString('o')
                logPath = $script:LogPath
                resultPath = $script:ResultPath
                error = $_.Exception.Message
            })
        }
        Write-Log $_.Exception.Message 'ERROR'
        Write-Log "Log salvo em: $script:LogPath" 'ERROR'
        exit 1
    }
}

try {
    Write-Log "Início: $($script:StartTime.ToString('s'))"
    Write-Log "Log: $script:LogPath"
    Write-Log "Admin: $(Test-IsAdmin)"
    Ensure-ProxyEnvFromWinHttp

    $winget = Ensure-Winget
    Refresh-SessionPath

    $gitInfo = Ensure-GitAndBash -WingetPath $winget
    Refresh-SessionPath

    $nodeInfo = Ensure-NodeAndNpm -WingetPath $winget
    Refresh-SessionPath

    Ensure-WingetPackage -WingetPath $winget -Id 'EclipseAdoptium.Temurin.17.JDK' -DisplayName 'Java JDK (Temurin 17)'
    Ensure-WingetPackage -WingetPath $winget -Id 'ImageMagick.ImageMagick' -DisplayName 'ImageMagick'
    Ensure-WingetPackage -WingetPath $winget -Id '7zip.7zip' -DisplayName '7-Zip' -AllowFailureWhenNotAdmin $true
    $sevenZipDir = $null
    try { $sevenZipDir = Join-Path $env:ProgramFiles '7-Zip' } catch { $sevenZipDir = $null }
    if ($sevenZipDir -and (Test-Path $sevenZipDir)) {
        Ensure-PathUserContains -Dir $sevenZipDir
        Refresh-SessionPath
    }
    Ensure-Python -WingetPath $winget
    Refresh-SessionPath

    Ensure-OpenCode -BashPath $gitInfo.Bash
    Refresh-SessionPath

    Ensure-ClaudeCode -WingetPath $winget
    Refresh-SessionPath

    Ensure-WingetPackage -WingetPath $winget -Id 'GitHub.cli' -DisplayName 'GitHub CLI (gh)'
    Refresh-SessionPath

    Ensure-WingetPackage -WingetPath $winget -Id 'Google.Chrome' -DisplayName 'ChromeSetup (Google Chrome)' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'Notepad++.Notepad++' -DisplayName 'Notepad++' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'Anthropic.Claude' -DisplayName 'Claude Setup (Claude Desktop)' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'Anysphere.Cursor' -DisplayName 'CursorUserSetup (Cursor)' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'Codeium.Windsurf' -DisplayName 'WindsurfUserSetup (Windsurf)' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'Warp.Warp' -DisplayName 'WarpSetup (Warp)' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'ByteDance.Trae' -DisplayName 'Trae-Setup (Trae)' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'SST.OpenCodeDesktop' -DisplayName 'opencode-desktop-windows (OpenCode Desktop)' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'Microsoft.VisualStudioCode.Insiders' -DisplayName 'Visual Studio Code - Insiders' -AllowFailureWhenNotAdmin $true
    Ensure-WslUi -WingetPath $winget
    Ensure-WingetPackage -WingetPath $winget -Id 'Google.Antigravity' -DisplayName 'Antigravity.exe' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'ZhipuAI.AutoClaw' -DisplayName 'autoclaw (AutoClaw)' -AllowFailureWhenNotAdmin $true
    Ensure-WingetPackage -WingetPath $winget -Id 'Perplexity.Comet' -DisplayName 'Perplexity (Comet)' -AllowFailureWhenNotAdmin $true
    Ensure-CodexInstaller -WingetPath $winget
    Refresh-SessionPath

    Ensure-NpmGlobalPackage -NpmCmd $nodeInfo.NpmCmd -Package '@google/gemini-cli' -DisplayName 'Gemini CLI (@google/gemini-cli)'
    Ensure-NpmGlobalPackage -NpmCmd $nodeInfo.NpmCmd -Package '@bonsai-ai/cli' -DisplayName 'Bonsai CLI (@bonsai-ai/cli)'
    Ensure-NpmGlobalPackage -NpmCmd $nodeInfo.NpmCmd -Package '@vibe-kit/grok-cli' -DisplayName 'Grok CLI (@vibe-kit/grok-cli)'
    Ensure-NpmGlobalPackage -NpmCmd $nodeInfo.NpmCmd -Package '@qwen-code/qwen-code@latest' -DisplayName 'Qwen Code (@qwen-code/qwen-code)'
    Ensure-NpmGlobalPackage -NpmCmd $nodeInfo.NpmCmd -Package '@github/copilot' -DisplayName 'GitHub Copilot CLI (@github/copilot)'
    Ensure-NpmGlobalPackage -NpmCmd $nodeInfo.NpmCmd -Package '@openai/codex' -DisplayName 'OpenAI Codex CLI (@openai/codex)'
    Ensure-OpenClaw -NpmCmd $nodeInfo.NpmCmd
    Refresh-SessionPath

    Ensure-ClaudeCodeDefaults -GitBashPath $gitInfo.Bash
    Refresh-SessionPath

    Ensure-ClaudeHookConfigsHealthy -GitBashPath $gitInfo.Bash
    Refresh-SessionPath

    Ensure-Aider
    Refresh-SessionPath

    Ensure-Goose -BashPath $gitInfo.Bash
    Refresh-SessionPath

    $repoDir = Join-Path $CloneBaseDir 'gemini-cli'
    Ensure-RepoClone -GitExe $gitInfo.Git -RepoUrl 'https://github.com/heartyguy/gemini-cli' -TargetDir $repoDir

    $opencodeExe = Join-Path (Join-Path $env:USERPROFILE '.opencode\bin') 'opencode.exe'
    $geminiCmd = Join-Path $nodeInfo.NpmBin 'gemini.cmd'
    $bonsaiCmd = Join-Path $nodeInfo.NpmBin 'bonsai.cmd'
    $grokCmd = Join-Path $nodeInfo.NpmBin 'grok.cmd'
    $qwenCmd = Join-Path $nodeInfo.NpmBin 'qwen.cmd'
    $copilotCmd = Join-Path $nodeInfo.NpmBin 'copilot.cmd'
    $codexCmd = Join-Path $nodeInfo.NpmBin 'codex.cmd'
    $openclawCmd = Join-Path $nodeInfo.NpmBin 'openclaw.cmd'

    Write-Log 'Resumo:'
    Write-Log "CLAUDE_CODE_GIT_BASH_PATH: $([Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH','User'))"
    Write-Log "git: $(& $gitInfo.Git --version)"
    Write-Log "node: $(& $nodeInfo.Node -v)"
    Write-Log "npm: $(& $nodeInfo.NpmCmd --version)"
    $javaExe = Resolve-CommandPath -Name 'java'
    if ($javaExe) { Write-Log "java: $(Invoke-NativeFirstLine -Exe $javaExe -Args @('-version'))" } else { Write-Log 'java: NÃO ENCONTRADO' 'WARN' }
    $magickExe = Resolve-CommandPath -Name 'magick'
    if ($magickExe) { Write-Log "magick: $(Invoke-NativeFirstLine -Exe $magickExe -Args @('-version'))" } else { Write-Log 'magick: NÃO ENCONTRADO' 'WARN' }
    $sevenZipExe = Resolve-CommandPath -Name '7z'
    if ($sevenZipExe) { Write-Log "7z: $(Invoke-NativeFirstLine -Exe $sevenZipExe -Args @()) ($sevenZipExe)" } else { Write-Log '7z: NÃO ENCONTRADO' 'WARN' }
    $pythonExe = Resolve-CommandPath -Name 'python'
    if ($pythonExe) { Write-Log "python: $(Invoke-NativeFirstLine -Exe $pythonExe -Args @('--version')) ($pythonExe)" } else { Write-Log 'python: NÃO ENCONTRADO' 'WARN' }
    $pipExe = Resolve-CommandPath -Name 'pip'
    if ($pipExe) { Write-Log "pip: $(Invoke-NativeFirstLine -Exe $pipExe -Args @('--version')) ($pipExe)" } else { Write-Log 'pip: NÃO ENCONTRADO' 'WARN' }
    $claudeExe = Resolve-CommandPath -Name 'claude'
    if ($claudeExe) { Write-Log "claude: $(Invoke-NativeFirstLine -Exe $claudeExe -Args @('--version')) ($claudeExe)" } else { Write-Log 'claude: NÃO ENCONTRADO' 'WARN' }
    $ghExe = Resolve-CommandPath -Name 'gh'
    if ($ghExe) { Write-Log "gh: $(Invoke-NativeFirstLine -Exe $ghExe -Args @('--version')) ($ghExe)" } else { Write-Log 'gh: NÃO ENCONTRADO' 'WARN' }
    if (Test-Path $opencodeExe) { Write-Log "opencode: $(& $opencodeExe --version) ($opencodeExe)" } else { Write-Log "opencode: NÃO ENCONTRADO ($opencodeExe)" 'WARN' }
    if (Test-Path $geminiCmd) { Write-Log "gemini: $(& $geminiCmd --version) ($geminiCmd)" } else { Write-Log "gemini: NÃO ENCONTRADO ($geminiCmd)" 'WARN' }
    if (Test-Path $bonsaiCmd) { Write-Log "bonsai: instalado ($bonsaiCmd)" } else { Write-Log "bonsai: NÃO ENCONTRADO ($bonsaiCmd)" 'WARN' }
    if (Test-Path $grokCmd) { Write-Log "grok: $(& $grokCmd --version) ($grokCmd)" } else { Write-Log "grok: NÃO ENCONTRADO ($grokCmd)" 'WARN' }
    if (Test-Path $qwenCmd) { Write-Log "qwen: $(Invoke-NativeFirstLine -Exe $qwenCmd -Args @('--version')) ($qwenCmd)" } else { Write-Log "qwen: NÃO ENCONTRADO ($qwenCmd)" 'WARN' }
    if (Test-Path $copilotCmd) { Write-Log "copilot: $(Invoke-NativeFirstLine -Exe $copilotCmd -Args @('--version')) ($copilotCmd)" } else { Write-Log "copilot: NÃO ENCONTRADO ($copilotCmd)" 'WARN' }
    if (Test-Path $codexCmd) { Write-Log "codex: $(Invoke-NativeFirstLine -Exe $codexCmd -Args @('--version')) ($codexCmd)" } else { Write-Log "codex: NÃO ENCONTRADO ($codexCmd)" 'WARN' }
    $codexPath = Resolve-CommandPath -Name 'codex'
    if ($codexPath) {
        $ext = ([IO.Path]::GetExtension($codexPath)).ToLowerInvariant()
        if (($ext -eq '.exe') -and (-not (Test-Path $codexCmd))) {
            Write-Log "codex (PATH) aponta para um .exe ($codexPath). Se o Codex Desktop estiver crashando, priorize o codex.cmd do npm para CLI e ajuste o config.toml do app." 'WARN'
        } else {
            Write-Log "codex (PATH): $codexPath"
        }
    }
    if (Test-Path $openclawCmd) { Write-Log "openclaw: $(& $openclawCmd --version) ($openclawCmd)" } else { Write-Log "openclaw: NÃO ENCONTRADO ($openclawCmd)" 'WARN' }
    $aiderExe = Resolve-CommandPath -Name 'aider'
    if ($aiderExe) { Write-Log "aider: $(Invoke-NativeFirstLine -Exe $aiderExe -Args @('--version')) ($aiderExe)" } else { Write-Log 'aider: NÃO ENCONTRADO' 'WARN' }
    $gooseExe = Resolve-CommandPath -Name 'goose'
    if ($gooseExe) { Write-Log "goose: $(Invoke-NativeFirstLine -Exe $gooseExe -Args @('--version')) ($gooseExe)" } else { Write-Log 'goose: NÃO ENCONTRADO' 'WARN' }
    $desktopWinget = @(
        @{ Name = 'ChromeSetup'; Id = 'Google.Chrome' },
        @{ Name = 'Notepad++'; Id = 'Notepad++.Notepad++' },
        @{ Name = 'Claude Setup'; Id = 'Anthropic.Claude' },
        @{ Name = 'CursorUserSetup'; Id = 'Anysphere.Cursor' },
        @{ Name = 'WindsurfUserSetup'; Id = 'Codeium.Windsurf' },
        @{ Name = 'WarpSetup'; Id = 'Warp.Warp' },
        @{ Name = 'Trae-Setup'; Id = 'ByteDance.Trae' },
        @{ Name = 'opencode-desktop-windows'; Id = 'SST.OpenCodeDesktop' },
        @{ Name = 'Visual Studio Code - Insiders'; Id = 'Microsoft.VisualStudioCode.Insiders' },
        @{ Name = 'WSL UI'; Id = 'OctasoftLtd.WSLUI' },
        @{ Name = 'Antigravity.exe'; Id = 'Google.Antigravity' },
        @{ Name = 'autoclaw'; Id = 'ZhipuAI.AutoClaw' },
        @{ Name = 'Perplexity'; Id = 'Perplexity.Comet' },
        @{ Name = 'Codex Installer'; Id = 'OpenAI.Codex' }
    )
    foreach ($app in $desktopWinget) {
        $ok = Test-WingetPackageInstalled -WingetPath $winget -Id $app.Id
        if ($ok) {
            Write-Log ("desktop: {0} (winget: {1})" -f $app.Name, $app.Id)
        } else {
            Write-Log ("desktop: {0} NÃO ENCONTRADO (winget: {1})" -f $app.Name, $app.Id) 'WARN'
        }
    }
    Write-Log "repo gemini-cli: $repoDir (exists=$(Test-Path $repoDir))"

    $elapsed = New-TimeSpan -Start $script:StartTime -End (Get-Date)
    Write-Log ("Concluído em {0:c}" -f $elapsed)
    Write-Log "Log salvo em: $script:LogPath"
} catch {
    if (-not [string]::IsNullOrWhiteSpace($script:ResultPath)) {
        Write-BootstrapExecutionResultFile -Path $script:ResultPath -Value ([ordered]@{
            status = 'error'
            generatedAt = (Get-Date).ToString('o')
            logPath = $script:LogPath
            resultPath = $script:ResultPath
            error = $_.Exception.Message
        })
    }
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log "Log salvo em: $script:LogPath" 'ERROR'
    exit 1
}
