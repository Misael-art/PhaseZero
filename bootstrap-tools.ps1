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
    [string]$SecretsImportPath,
    [string]$SecretsActivateProvider,
    [string]$SecretsActivateCredential,
    [switch]$Interactive,
    [switch]$ListProfiles,
    [switch]$ListHostHealthModes,
    [switch]$ListComponents,
    [switch]$UiContractJson,
    [switch]$BootstrapUiLibraryMode,
    [switch]$SecretsList,
    [switch]$SecretsValidateAll,
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

function Test-BootstrapSensitiveEnvName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return ($Name -match '(^|_)(API_KEY|KEY|TOKEN|SECRET|PASSWORD|PASS|PAT)($|_)')
}

function Get-BootstrapEnvValueForLog {
    param(
        [string]$Name,
        [string]$Value
    )

    if (Test-BootstrapSensitiveEnvName -Name $Name) {
        return '[redacted]'
    }

    return $Value
}

function Notify-BootstrapEnvironmentChanged {
    try {
        if (-not ('BootstrapNativeMethods' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class BootstrapNativeMethods {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult
    );
}
"@
        }

        $result = [IntPtr]::Zero
        $null = [BootstrapNativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff,
            0x001A,
            [IntPtr]::Zero,
            'Environment',
            0x0002,
            5000,
            [ref]$result
        )
    } catch {
    }
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
        $output = & $Exe @Args 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = 0
        }
        foreach ($item in @($output)) {
            $line = [string]$item
            if ($line -match "`0") { $line = $line -replace "`0", '' }
            Add-Content -Path $script:LogPath -Value $line -Encoding utf8
            Write-Host $line
        }
        return [int]$exitCode
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
    $logValue = Get-BootstrapEnvValueForLog -Name $Name -Value $Value
    if ($current -ne $Value) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
        Notify-BootstrapEnvironmentChanged
        Write-Log "Definido $Name (Usuário) = $logValue"
    } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
        Write-Log "Já definido $Name (Usuário) = $logValue"
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

function Get-BootstrapAppInstallerPackage {
    try {
        return Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue | Select-Object -First 1
    } catch {
        return $null
    }
}

function Get-BootstrapPendingRebootReasons {
    $reasons = New-Object System.Collections.Generic.List[string]

    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            $reasons.Add('Component Based Servicing')
        }
    } catch {
    }

    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            $reasons.Add('Windows Update')
        }
    } catch {
    }

    try {
        $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
        if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
            $reasons.Add('PendingFileRenameOperations')
        }
    } catch {
    }

    try {
        $updateExeVolatile = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Updates' -Name 'UpdateExeVolatile' -ErrorAction SilentlyContinue
        if ($updateExeVolatile -and ($updateExeVolatile.UpdateExeVolatile -as [int]) -gt 0) {
            $reasons.Add('UpdateExeVolatile')
        }
    } catch {
    }

    return @($reasons | Select-Object -Unique)
}

function Test-BootstrapTcpEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [int]$Port = 443,
        [int]$TimeoutMilliseconds = 4000
    )

    $client = $null
    try {
        [void][Net.Dns]::GetHostAddresses($HostName)
        $client = New-Object Net.Sockets.TcpClient
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) {
            $client.Dispose()
        }
    }
}

function Get-BootstrapPreflightRequirements {
    param([string[]]$ResolvedComponents)

    $catalog = Get-BootstrapComponentCatalog
    $requiresNetwork = $false
    $requiresWinget = $false
    $needsGithub = $false
    $needsMicrosoft = $false
    $needsOpenCode = $false

    foreach ($componentName in @($ResolvedComponents)) {
        $componentDef = $catalog[$componentName]
        if (-not $componentDef) { continue }

        switch ($componentDef.Kind) {
            'system-core' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'git-core' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'node-core' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'python-core' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'sevenzip' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'winget' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'wsl-core' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'wsl-ui' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'claude-code' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'vscode-extensions' {
                $requiresNetwork = $true
            }
            'bootstrap-mcps' {
                $requiresNetwork = $true
            }
            'codex-installer' {
                $requiresNetwork = $true
                $requiresWinget = $true
                $needsMicrosoft = $true
            }
            'npm' {
                $requiresNetwork = $true
            }
            'uvtool' {
                $requiresNetwork = $true
            }
            'goose' {
                $requiresNetwork = $true
                $needsGithub = $true
            }
            'opencode' {
                $requiresNetwork = $true
                $needsOpenCode = $true
            }
            'openclaw' {
                $requiresNetwork = $true
            }
            'repo-clone' {
                $requiresNetwork = $true
                $needsGithub = $true
            }
            'steamdeck-tools' {
                $requiresNetwork = $true
                $needsGithub = $true
            }
        }
    }

    $connectivityGroups = New-Object System.Collections.Generic.List[object]
    if ($needsMicrosoft) {
        $connectivityGroups.Add([pscustomobject]@{
            Name = 'winget-store'
            Hosts = @('cdn.winget.microsoft.com', 'storeedgefd.dsx.mp.microsoft.com')
        })
    }
    if ($needsGithub) {
        $connectivityGroups.Add([pscustomobject]@{
            Name = 'github'
            Hosts = @('github.com', 'api.github.com', 'objects.githubusercontent.com')
        })
    }
    if ($needsOpenCode) {
        $connectivityGroups.Add([pscustomobject]@{
            Name = 'opencode'
            Hosts = @('opencode.ai')
        })
    }

    return [ordered]@{
        RequiresNetwork = $requiresNetwork
        RequiresWinget = $requiresWinget
        ConnectivityGroups = $(if ($connectivityGroups.Count -gt 0) { $connectivityGroups.ToArray() } else { @() })
    }
}

function Invoke-BootstrapExecutionPreflight {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string[]]$ResolvedComponents
    )

    if ($State.PreflightDone) { return }

    Write-Log 'Executando preflight operacional...'
    Write-Log "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Log "LanguageMode: $($ExecutionContext.SessionState.LanguageMode)"
    Ensure-ProxyEnvFromWinHttp

    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "Bootstrap requer FullLanguage. Modo atual: $($ExecutionContext.SessionState.LanguageMode)"
    }

    $requirements = Get-BootstrapPreflightRequirements -ResolvedComponents $ResolvedComponents
    $pendingRebootReasons = @(Get-BootstrapPendingRebootReasons)
    if ($pendingRebootReasons.Count -gt 0) {
        Write-Log ("Reinicio pendente detectado: {0}. Recomendo reiniciar antes de prosseguir para evitar falhas de Store/winget/WSL." -f ($pendingRebootReasons -join ', ')) 'WARN'
    } else {
        Write-Log 'Nenhum reinicio pendente detectado.'
    }

    $wingetPath = $null
    $appInstaller = $null
    if ($requirements.RequiresWinget) {
        $appInstaller = Get-BootstrapAppInstallerPackage
        if ($appInstaller) {
            Write-Log ("App Installer detectado: {0} ({1})" -f $appInstaller.Name, $appInstaller.Version)
        } else {
            Write-Log 'App Installer nao detectado via Get-AppxPackage.' 'WARN'
        }

        $wingetPath = Get-Winget
        if (-not $wingetPath) {
            if ($appInstaller) {
                throw 'Preflight: App Installer presente, mas o winget ainda nao esta acessivel nesta sessao. Feche e reabra o terminal/Explorer, faca logoff ou reinicie a sessao e tente novamente.'
            }
            throw 'Preflight: winget/App Installer indisponivel. Em um Windows 11 recem-instalado, instale ou atualize o App Installer (Microsoft.DesktopAppInstaller) e execute novamente.'
        }
        Write-Log "Preflight: winget acessivel em $wingetPath"
    }

    $connectivitySummary = New-Object System.Collections.Generic.List[object]
    if ($requirements.RequiresNetwork) {
        foreach ($group in @($requirements.ConnectivityGroups)) {
            $groupReachable = $false
            $hostResults = New-Object System.Collections.Generic.List[object]

            foreach ($hostName in @($group.Hosts)) {
                $reachable = Test-BootstrapTcpEndpoint -HostName $hostName
                $hostResults.Add([ordered]@{
                    host = $hostName
                    reachable = $reachable
                })

                if ($reachable) {
                    $groupReachable = $true
                    Write-Log ("Conectividade OK: {0}:443" -f $hostName)
                } else {
                    Write-Log ("Conectividade indisponivel: {0}:443" -f $hostName) 'WARN'
                }
            }

            $connectivitySummary.Add([ordered]@{
                group = $group.Name
                reachable = $groupReachable
                hosts = $(if ($hostResults.Count -gt 0) { $hostResults.ToArray() } else { @() })
            })

            if (-not $groupReachable) {
                throw "Preflight: conectividade minima ausente para '$($group.Name)'. Hosts testados: $(@($group.Hosts) -join ', ')."
            }
        }
    } else {
        Write-Log 'Preflight: execucao atual nao requer downloads externos.'
    }

    if ($wingetPath) {
        $State.Winget = $wingetPath
    }

    $State.PreflightSummary = [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        requiresNetwork = $requirements.RequiresNetwork
        requiresWinget = $requirements.RequiresWinget
        pendingRebootReasons = @($pendingRebootReasons)
        wingetPath = $wingetPath
        appInstallerPresent = ($null -ne $appInstaller)
        connectivity = $(if ($connectivitySummary.Count -gt 0) { $connectivitySummary.ToArray() } else { @() })
    }
    $State.PreflightDone = $true
    Write-Log 'Preflight operacional concluido.'
}

function Invoke-NativeWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [int]$MaxAttempts = 2,
        [int]$InitialDelaySeconds = 3
    )

    $attempt = 0
    $delaySeconds = [Math]::Max(1, $InitialDelaySeconds)
    $lastExitCode = -1

    while ($attempt -lt $MaxAttempts) {
        $attempt++
        if ($attempt -gt 1) {
            Write-Log ("Repetindo operacao: {0} (tentativa {1}/{2})" -f $OperationName, $attempt, $MaxAttempts) 'WARN'
        }

        $lastExitCode = Invoke-NativeWithLog -Exe $Exe -Args $Args
        if ($lastExitCode -eq 0) {
            return 0
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Log ("Falha em {0} (exit={1}). Nova tentativa em {2}s." -f $OperationName, $lastExitCode, $delaySeconds) 'WARN'
            Start-Sleep -Seconds $delaySeconds
            $delaySeconds = [Math]::Min(15, $delaySeconds * 2)
        }
    }

    return $lastExitCode
}

function Invoke-WebRequestWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$OperationName = 'download',
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 3
    )

    $attempt = 0
    $delaySeconds = [Math]::Max(1, $InitialDelaySeconds)
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            if ($attempt -gt 1) {
                Write-Log ("Repetindo download: {0} (tentativa {1}/{2})" -f $OperationName, $attempt, $MaxAttempts) 'WARN'
            }
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile | Out-Null
            return
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            Write-Log ("Falha em {0}: {1}. Nova tentativa em {2}s." -f $OperationName, $_.Exception.Message, $delaySeconds) 'WARN'
            Start-Sleep -Seconds $delaySeconds
            $delaySeconds = [Math]::Min(15, $delaySeconds * 2)
        }
    }
}

function Get-ClaudeHookConfigCandidatePaths {
    $candidates = @()
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    $localAppDataPath = Get-BootstrapLocalAppDataPath

    if ($appDataPath) {
        $candidates += (Join-Path $appDataPath 'Claude\claude_desktop_config.json')
    }
    if ($localAppDataPath) {
        $candidates += (Join-Path $localAppDataPath 'Claude\claude_desktop_config.json')
    }

    if ($userHome) {
        $candidates += (Join-Path $userHome '.claude\settings.json')
    }
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot '.claude\settings.json')
    }

    $projectRoots = @()
    if ($userHome) {
        $projectRoots += (Join-Path $userHome 'Documents')
        $projectRoots += (Join-Path $userHome 'Projects')
        $projectRoots += (Join-Path $userHome 'Work')
        $projectRoots += (Join-Path $userHome 'Workspace')
        $projectRoots += (Join-Path $userHome 'Source')
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

    $userHome = Get-BootstrapUserHomePath
    if ([string]::IsNullOrWhiteSpace($userHome)) { return }
    $settingsDir = Join-Path $userHome '.claude'
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
    function Get-TargetPropertyState {
        param(
            [Parameter(Mandatory = $true)]$Target,
            [Parameter(Mandatory = $true)][string]$Name
        )

        if ($Target -is [System.Collections.IDictionary]) {
            foreach ($key in @($Target.Keys)) {
                if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [pscustomobject]@{
                        Exists = $true
                        Key = $key
                        Value = $Target[$key]
                    }
                }
            }

            return [pscustomobject]@{
                Exists = $false
                Key = $Name
                Value = $null
            }
        }

        $prop = $null
        try { $prop = [System.Management.Automation.PSObject]::AsPSObject($Target).Properties[$Name] } catch { $prop = $null }
        if ($null -ne $prop) {
            $value = $null
            try { $value = $prop.Value } catch { $value = $null }
            return [pscustomobject]@{
                Exists = $true
                Key = $Name
                Value = $value
            }
        }

        return [pscustomobject]@{
            Exists = $false
            Key = $Name
            Value = $null
        }
    }
    function Set-TargetPropertyValue {
        param(
            [Parameter(Mandatory = $true)]$Target,
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)]$Value
        )

        $state = Get-TargetPropertyState -Target $Target -Name $Name
        if ($Target -is [System.Collections.IDictionary]) {
            $Target[$state.Key] = $Value
            return
        }

        $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
    function Ensure-PropValue {
        param(
            [Parameter(Mandatory = $true)]$Target,
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)]$Value
        )
        $state = Get-TargetPropertyState -Target $Target -Name $Name
        if ((-not $state.Exists) -or ($state.Value -ne $Value)) {
            Set-TargetPropertyValue -Target $Target -Name $Name -Value $Value
            Set-Variable -Name changed -Value $true -Scope 1
        }
    }
    function Ensure-ObjectProp {
        param(
            [Parameter(Mandatory = $true)]$Target,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $state = Get-TargetPropertyState -Target $Target -Name $Name
        $v = $state.Value
        if ((-not $v) -or (($v -isnot [pscustomobject]) -and ($v -isnot [System.Collections.IDictionary]))) {
            $v = [ordered]@{}
            Set-TargetPropertyValue -Target $Target -Name $Name -Value $v
            Set-Variable -Name changed -Value $true -Scope 1
        }
        return $v
    }
    function Ensure-StringArrayProp {
        param(
            [Parameter(Mandatory = $true)]$Target,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $state = Get-TargetPropertyState -Target $Target -Name $Name
        $v = $state.Value
        if ($v -is [string]) {
            $v = @([string]$v)
            Set-TargetPropertyValue -Target $Target -Name $Name -Value $v
            Set-Variable -Name changed -Value $true -Scope 1
        } elseif (($null -eq $v) -or ($v -is [System.Collections.IDictionary]) -or (-not ($v -is [System.Collections.IEnumerable]))) {
            $v = @()
            Set-TargetPropertyValue -Target $Target -Name $Name -Value $v
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
        Set-TargetPropertyValue -Target $permObj -Name 'allow' -Value @($newAllow)
        $changed = $true
    }

    $newDeny = Merge-StringArrayUniqueCI -Existing $deny -Add $denyWanted
    if (@($newDeny).Count -ne @($deny).Count) {
        Set-TargetPropertyValue -Target $permObj -Name 'deny' -Value $newDeny
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
    if (-not $winget) {
        $appInstaller = Get-BootstrapAppInstallerPackage

        if ($appInstaller) {
            throw 'winget não está acessível no PATH, embora o App Installer esteja presente. Feche e reabra o terminal/Explorer, faça logoff ou reinicie a sessão e tente novamente.'
        }

        throw 'winget não encontrado. Em um Windows 11 recém-instalado, instale ou atualize o App Installer (Microsoft.DesktopAppInstaller) pela Microsoft Store e execute novamente.'
    }
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
        $exitCode = Invoke-NativeWithRetry -Exe $WingetPath -Args (@($commonArgs) + @('--scope', 'user')) -OperationName "$DisplayName via winget --scope user"
        if ($exitCode -ne 0) {
            Write-Log "Falha ao instalar $DisplayName com --scope user (winget). Tentando novamente sem --scope..." 'WARN'
        }
    }
    if ($exitCode -ne 0) {
        $exitCode = Invoke-NativeWithRetry -Exe $WingetPath -Args $commonArgs -OperationName "$DisplayName via winget"
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
    $exitCode = Invoke-NativeWithRetry -Exe $pythonExe -Args @('-m', 'pip', 'install', '-U', '--upgrade-strategy', 'only-if-needed', 'uv') -OperationName 'instalacao do uv via pip'
    if ($exitCode -ne 0) { throw "Falha ao instalar uv via pip (exit=$exitCode)." }

    Refresh-SessionPath
    $uvExe = Resolve-CommandPath -Name 'uv'
    if (-not $uvExe) { throw 'Instalação do uv concluída, mas o comando uv não foi encontrado no PATH.' }

    $ver = Invoke-NativeFirstLine -Exe $uvExe -Args @('--version')
    Write-Log "uv instalado: $ver ($uvExe)"
    return $uvExe
}

function Get-BootstrapNonEmptyStringArray {
    param([AllowNull()][string[]]$Values = @())

    return @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Ensure-UvToolPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string]$DisplayName = $Package,
        [string[]]$VersionArgs = @('--version'),
        [string[]]$InstallArgs = @()
    )

    $sanitizedVersionArgs = Get-BootstrapNonEmptyStringArray -Values $VersionArgs
    $sanitizedInstallArgs = Get-BootstrapNonEmptyStringArray -Values $InstallArgs

    $exe = Resolve-CommandPath -Name $CommandName
    if ($exe) {
        $ver = Invoke-NativeFirstLine -Exe $exe -Args $sanitizedVersionArgs
        Write-Log "$DisplayName já instalado: $ver ($exe)"
        return
    }

    $uvExe = Ensure-Uv
    $localBin = Join-Path (Get-BootstrapUserHomePath) '.local\bin'
    $null = New-Item -Path $localBin -ItemType Directory -Force
    $env:UV_TOOL_BIN_DIR = $localBin

    Write-Log "Instalando $DisplayName ($Package) via uv tool..."
    $installCommandArgs = @('tool', 'install', '--reinstall') + $sanitizedInstallArgs + @($Package)
    $exitCode = Invoke-NativeWithRetry -Exe $uvExe -Args $installCommandArgs -OperationName "$DisplayName via uv tool"

    Ensure-PathUserContains -Dir $localBin
    Refresh-SessionPath

    $exe = Resolve-CommandPath -Name $CommandName
    if (-not $exe) { throw "Instalação do $DisplayName concluída, mas o comando $CommandName não foi encontrado no PATH." }

    if ($exitCode -ne 0) {
        Write-Log ("{0} retornou exit={1}, mas o comando {2} foi localizado no PATH; o bootstrap vai validar o binario e continuar." -f $DisplayName, $exitCode, $CommandName) 'WARN'
    }

    $ver = Invoke-NativeFirstLine -Exe $exe -Args $sanitizedVersionArgs
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

    $localBin = Join-Path (Get-BootstrapUserHomePath) '.local\bin'
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
            Invoke-WebRequestWithRetry -Uri $url -OutFile $zipPath -OperationName 'download do goose'
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
    $userProfileDir = Get-BootstrapUserHomePath
    $binDir = Join-Path $userProfileDir '.opencode\bin'
    $exe = Join-Path $binDir 'opencode.exe'

    if (Test-Path $exe) {
        $ver = & $exe --version
        Write-Log "opencode já instalado: $ver ($exe)"
    } else {
        Write-Log 'Instalando opencode via script oficial...'
        $exitCode = Invoke-NativeWithRetry -Exe $BashPath -Args @('-lc', 'set -e; curl -fsSL https://opencode.ai/install | bash') -OperationName 'instalacao do opencode via script oficial'
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
    $exitCode = Invoke-NativeWithRetry -Exe $GitExe -Args @('clone', $RepoUrl, $TargetDir) -OperationName "clone de $RepoUrl"
    if ($exitCode -ne 0) { throw "Falha ao clonar repositório (exit=$exitCode): $RepoUrl" }
    Write-Log "Clone concluído: $TargetDir"
}

function Resolve-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-BootstrapUserHomePath {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { return $env:USERPROFILE }
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { return $env:HOME }
    if (-not [string]::IsNullOrWhiteSpace($env:HOMEDRIVE) -and -not [string]::IsNullOrWhiteSpace($env:HOMEPATH)) {
        return ($env:HOMEDRIVE + $env:HOMEPATH)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $env:LOCALAPPDATA }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { return $env:TEMP }
    if (-not [string]::IsNullOrWhiteSpace($env:TMP)) { return $env:TMP }
    try {
        $folder = [Environment]::GetFolderPath('UserProfile')
        if (-not [string]::IsNullOrWhiteSpace($folder)) { return $folder }
    } catch {
    }
    return (Get-Location).Path
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
        return ,@($items)
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

    if ($normalizedDefaults -is [System.Array]) {
        if ($normalizedCurrent -is [System.Array]) {
            return ,@($normalizedCurrent)
        }
        return ,@($normalizedDefaults)
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
        return ,@($items)
    }

    return $InputObject
}

function Normalize-BootstrapObjectArray {
    param($Value)

    if ($null -eq $Value) { return ,@() }

    if (($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject])) {
        $propertyCount = if ($Value -is [pscustomobject]) { @($Value.PSObject.Properties).Count } else { @($Value.Keys).Count }
        if ($propertyCount -eq 0) { return ,@() }
        return ,@((ConvertTo-BootstrapHashtable -InputObject $Value))
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += @(ConvertTo-BootstrapHashtable -InputObject $item)
        }
        return ,@($items)
    }

    return ,@($Value)
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

function Test-BootstrapDirectoryWritable {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $null = New-Item -Path $Path -ItemType Directory -Force
        $probePath = Join-Path $Path ('.write-test-{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
        'bootstrap-write-test' | Set-Content -Path $probePath -Encoding utf8
        Remove-Item -Path $probePath -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-BootstrapDataRoot {
    $cachedDataRoot = $null
    $cachedVariable = Get-Variable -Name BootstrapDataRoot -Scope Script -ErrorAction SilentlyContinue
    if ($cachedVariable) {
        $cachedDataRoot = [string]$cachedVariable.Value
    }

    if (-not [string]::IsNullOrWhiteSpace($cachedDataRoot) -and (Test-Path $cachedDataRoot)) {
        $script:BootstrapDataRoot = $cachedDataRoot
        return $script:BootstrapDataRoot
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:BOOTSTRAP_DATA_ROOT)) {
        $candidates += $env:BOOTSTRAP_DATA_ROOT
    }

    $userHome = Get-BootstrapUserHomePath
    if (-not [string]::IsNullOrWhiteSpace($userHome)) {
        $candidates += (Join-Path $userHome '.bootstrap-tools')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'bootstrap-tools')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $candidates += (Join-Path $env:TEMP 'bootstrap-tools')
    }
    $candidates += (Join-Path (Get-Location).Path '.bootstrap-tools')

    foreach ($candidate in @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-BootstrapDirectoryWritable -Path $candidate) {
            $script:BootstrapDataRoot = $candidate
            return $script:BootstrapDataRoot
        }
    }

    $script:BootstrapDataRoot = (Join-Path (Get-Location).Path '.bootstrap-tools')
    return $script:BootstrapDataRoot
}

function Get-BootstrapAppDataPath {
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { return $env:APPDATA }
    return (Join-Path (Get-BootstrapUserHomePath) 'AppData\Roaming')
}

function Get-BootstrapLocalAppDataPath {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $env:LOCALAPPDATA }
    return (Join-Path (Get-BootstrapUserHomePath) 'AppData\Local')
}

function Get-BootstrapSecretsPath {
    return (Join-Path (Get-BootstrapDataRoot) 'bootstrap-secrets.json')
}

function Get-BootstrapPreferredFilePath {
    param(
        [string[]]$Candidates,
        [string]$DefaultPath
    )

    $normalized = @($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    foreach ($candidate in $normalized) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    foreach ($candidate in $normalized) {
        $parent = Split-Path -Path $candidate -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path $parent)) {
            return $candidate
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DefaultPath)) {
        return $DefaultPath
    }
    if ($normalized.Count -gt 0) {
        return $normalized[0]
    }
    return $null
}

function Get-BootstrapSecretsKnownTargets {
    return @('userEnv', 'claudeCode', 'claudeDesktop', 'cursor', 'windsurf', 'trae', 'openCode', 'vsCode', 'roo', 'cline', 'continue', 'zed', 'zCode', 'openClaw', 'comet')
}

function Get-BootstrapSecretsProviderCatalog {
    return (ConvertTo-BootstrapHashtable -InputObject ([ordered]@{
        anthropic = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'anthropic'
            defaults = [ordered]@{}
            aliases = @('anthropic', 'claude')
            tokenPatterns = @('sk-ant-[A-Za-z0-9_\-]+')
        }
        openai = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'openaiCompatible'
            defaults = [ordered]@{
                baseUrl = 'https://api.openai.com/v1'
                organizationId = ''
            }
            aliases = @('openai', 'chatgpt')
            tokenPatterns = @('sk-proj-[A-Za-z0-9_\-]+', 'sk-[A-Za-z0-9_\-]{16,}')
        }
        google = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'google'
            defaults = [ordered]@{}
            aliases = @('google', 'gemini', 'google ai', 'google ai studio', 'googlestudio')
            tokenPatterns = @('AIza[0-9A-Za-z\-_]{20,}')
        }
        xai = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'openaiCompatible'
            defaults = [ordered]@{
                baseUrl = 'https://api.x.ai/v1'
            }
            aliases = @('xai', 'x.ai', 'grok')
            tokenPatterns = @('xai-[A-Za-z0-9_\-]{12,}', 'sk-[A-Za-z0-9_\-]{16,}')
        }
        openrouter = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'openaiCompatible'
            defaults = [ordered]@{
                baseUrl = 'https://openrouter.ai/api/v1'
            }
            aliases = @('openrouter')
            tokenPatterns = @('sk-or-v1-[A-Za-z0-9]+')
        }
        github = [ordered]@{
            secretKind = 'token'
            validationKind = 'github'
            defaults = [ordered]@{}
            aliases = @('github')
            tokenPatterns = @('github_pat_[A-Za-z0-9_]+', 'gh[pousr]_[A-Za-z0-9_]+')
        }
        moonshot = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'openaiCompatible'
            defaults = [ordered]@{
                baseUrl = 'https://api.moonshot.ai/v1'
            }
            aliases = @('moonshot', 'kimi')
            tokenPatterns = @('sk-[A-Za-z0-9_\-]{12,}', 'ak-[A-Za-z0-9_\-]{12,}')
        }
        deepseek = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'openaiCompatible'
            defaults = [ordered]@{
                baseUrl = 'https://api.deepseek.com'
            }
            aliases = @('deepseek')
            tokenPatterns = @('sk-[A-Za-z0-9_\-]{12,}')
        }
        bonsai = [ordered]@{
            secretKind = 'token'
            validationKind = 'unsupported'
            defaults = [ordered]@{}
            aliases = @('bonsai', 'bonsai cloud')
            tokenPatterns = @('sk_cr_[A-Za-z0-9_\-]{12,}', 'c[0-9a-f]{24,}', 'ak-[A-Za-z0-9_\-]{12,}')
        }
        context7 = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'unsupported'
            defaults = [ordered]@{
                baseUrl = 'https://mcp.context7.com/mcp'
            }
            aliases = @('context7')
            tokenPatterns = @()
        }
        firecrawl = [ordered]@{
            secretKind = 'apiKey'
            validationKind = 'unsupported'
            defaults = [ordered]@{}
            aliases = @('firecrawl')
            tokenPatterns = @('fc-[A-Za-z0-9_\-]{8,}')
        }
        apify = [ordered]@{
            secretKind = 'token'
            validationKind = 'unsupported'
            defaults = [ordered]@{
                baseUrl = 'https://mcp.apify.com'
            }
            aliases = @('apify')
            tokenPatterns = @()
        }
        supabase = [ordered]@{
            secretKind = 'token'
            validationKind = 'unsupported'
            defaults = [ordered]@{
                baseUrl = 'https://mcp.supabase.com/mcp'
                projectRef = ''
                readOnly = 'true'
            }
            aliases = @('supabase')
            tokenPatterns = @()
        }
        netdata = [ordered]@{
            secretKind = 'token'
            validationKind = 'unsupported'
            defaults = [ordered]@{
                baseUrl = 'http://127.0.0.1:19999/mcp'
            }
            aliases = @('netdata')
            tokenPatterns = @()
        }
    }))
}

function New-BootstrapSecretValidationState {
    param(
        [string]$State = 'unknown',
        [string]$CheckedAt = '',
        [string]$Message = ''
    )

    return [ordered]@{
        state = if ([string]::IsNullOrWhiteSpace($State)) { 'unknown' } else { $State }
        checkedAt = if ([string]::IsNullOrWhiteSpace($CheckedAt)) { '' } else { $CheckedAt }
        message = if ([string]::IsNullOrWhiteSpace($Message)) { '' } else { $Message }
    }
}

function ConvertTo-BootstrapSafeSlug {
    param([string]$Text)

    $value = if ([string]::IsNullOrWhiteSpace($Text)) { 'default' } else { $Text.ToLowerInvariant() }
    $value = [regex]::Replace($value, '[^a-z0-9]+', '-')
    $value = $value.Trim('-')
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'default'
    }
    return $value
}

function New-BootstrapSecretCredentialId {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][string]$Label,
        [string[]]$ExistingIds = @()
    )

    $slug = ConvertTo-BootstrapSafeSlug -Text $Label
    $counter = 1
    while ($true) {
        $candidate = '{0}-{1}-{2:00}' -f $ProviderName.ToLowerInvariant(), $slug, $counter
        if (@($ExistingIds) -notcontains $candidate) {
            return $candidate
        }
        $counter += 1
    }
}

function Get-BootstrapSecretsProviderDefinitionTemplate {
    param([Parameter(Mandatory = $true)][string]$ProviderName)

    $catalog = Get-BootstrapSecretsProviderCatalog
    $providerMeta = @{}
    if ($catalog.Contains($ProviderName)) {
        $providerMeta = $catalog[$ProviderName]
    }

    $defaults = [ordered]@{}
    if ($providerMeta.ContainsKey('defaults') -and ($providerMeta['defaults'] -is [hashtable])) {
        foreach ($key in $providerMeta['defaults'].Keys) {
            $defaults[$key] = [string]$providerMeta['defaults'][$key]
        }
    }

    return [ordered]@{
        defaults = $defaults
        activeCredential = ''
        rotationOrder = @()
        credentials = [ordered]@{}
    }
}

function Normalize-BootstrapSecretValidation {
    param($Validation)

    $normalized = ConvertTo-BootstrapHashtable -InputObject $Validation
    if (-not ($normalized -is [hashtable])) {
        return (New-BootstrapSecretValidationState)
    }

    return (New-BootstrapSecretValidationState -State ([string]$normalized['state']) -CheckedAt ([string]$normalized['checkedAt']) -Message ([string]$normalized['message']))
}

function Normalize-BootstrapSecretCredential {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][string]$CredentialId,
        $CredentialData,
        [string]$DefaultSecretKind = 'secret'
    )

    $normalized = ConvertTo-BootstrapHashtable -InputObject $CredentialData
    if (-not ($normalized -is [hashtable])) {
        $normalized = @{}
    }

    $secret = ''
    foreach ($key in @('secret', 'apiKey', 'token', 'key')) {
        if ($normalized.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$normalized[$key])) {
            $secret = [string]$normalized[$key]
            break
        }
    }

    $displayName = if (-not [string]::IsNullOrWhiteSpace([string]$normalized['displayName'])) {
        [string]$normalized['displayName']
    } else {
        'Default'
    }

    $secretKind = if (-not [string]::IsNullOrWhiteSpace([string]$normalized['secretKind'])) {
        [string]$normalized['secretKind']
    } else {
        $DefaultSecretKind
    }

    $result = [ordered]@{
        displayName = $displayName
        secret = $secret
        secretKind = $secretKind
        validation = Normalize-BootstrapSecretValidation -Validation $normalized['validation']
    }

    foreach ($key in $normalized.Keys) {
        if ($key -in @('displayName', 'secret', 'apiKey', 'token', 'key', 'secretKind', 'validation')) { continue }
        $value = $normalized[$key]
        if ($value -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $result[$key] = $value
            }
            continue
        }
        if ($null -ne $value) {
            $result[$key] = $value
        }
    }

    return $result
}

function Convert-BootstrapSecretsProviderDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderName,
        $ProviderData
    )

    $catalog = Get-BootstrapSecretsProviderCatalog
    $template = Get-BootstrapSecretsProviderDefinitionTemplate -ProviderName $ProviderName
    $normalized = ConvertTo-BootstrapHashtable -InputObject $ProviderData
    if (-not ($normalized -is [hashtable])) {
        $normalized = @{}
    }

    $defaultSecretKind = if ($catalog.Contains($ProviderName)) { [string]$catalog[$ProviderName]['secretKind'] } else { 'secret' }
    $defaults = ConvertTo-BootstrapHashtable -InputObject $template['defaults']
    foreach ($key in $normalized.Keys) {
        if ($key -in @('defaults', 'credentials', 'rotationOrder', 'activeCredential', 'apiKey', 'token', 'secret', 'key', 'validation')) { continue }
        $value = $normalized[$key]
        if ($value -is [hashtable]) { continue }
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $defaults[$key] = [string]$value
        }
    }
    if ($normalized.ContainsKey('defaults') -and ($normalized['defaults'] -is [hashtable])) {
        foreach ($key in $normalized['defaults'].Keys) {
            $value = [string]$normalized['defaults'][$key]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $defaults[$key] = $value
            }
        }
    }

    $credentials = [ordered]@{}
    if ($normalized.ContainsKey('credentials') -and ($normalized['credentials'] -is [hashtable])) {
        foreach ($credentialId in $normalized['credentials'].Keys) {
            $credentials[[string]$credentialId] = Normalize-BootstrapSecretCredential -ProviderName $ProviderName -CredentialId ([string]$credentialId) -CredentialData $normalized['credentials'][$credentialId] -DefaultSecretKind $defaultSecretKind
        }
    }
    if ($credentials.Count -eq 0) {
        $legacySecret = ''
        foreach ($key in @('apiKey', 'token', 'secret', 'key')) {
            if ($normalized.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$normalized[$key])) {
                $legacySecret = [string]$normalized[$key]
                break
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($legacySecret)) {
            $credentialId = New-BootstrapSecretCredentialId -ProviderName $ProviderName -Label 'default'
            $credentials[$credentialId] = [ordered]@{
                displayName = 'Default'
                secret = $legacySecret
                secretKind = $defaultSecretKind
                validation = New-BootstrapSecretValidationState
            }
        }
    }

    $rotationOrder = New-Object System.Collections.Generic.List[string]
    if ($normalized.ContainsKey('rotationOrder') -and ($normalized['rotationOrder'] -is [System.Collections.IEnumerable])) {
        foreach ($entry in @($normalized['rotationOrder'])) {
            $value = [string]$entry
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if (-not $credentials.Contains($value)) { continue }
            if (-not $rotationOrder.Contains($value)) {
                $rotationOrder.Add($value)
            }
        }
    }
    foreach ($credentialId in $credentials.Keys) {
        if (-not $rotationOrder.Contains($credentialId)) {
            $rotationOrder.Add($credentialId)
        }
    }

    $activeCredential = [string]$normalized['activeCredential']
    if ([string]::IsNullOrWhiteSpace($activeCredential) -or -not $credentials.Contains($activeCredential)) {
        $activeCredential = if ($rotationOrder.Count -gt 0) { $rotationOrder[0] } else { '' }
    }

    return [ordered]@{
        defaults = $defaults
        activeCredential = $activeCredential
        rotationOrder = @($rotationOrder.ToArray())
        credentials = $credentials
    }
}

function Get-BootstrapSecretsTemplate {
    $catalog = Get-BootstrapSecretsProviderCatalog
    $providers = [ordered]@{}
    foreach ($providerName in $catalog.Keys) {
        $providers[$providerName] = Get-BootstrapSecretsProviderDefinitionTemplate -ProviderName $providerName
    }

    return [ordered]@{
        '$schema' = 'https://bootstrap.local/schemas/bootstrap-secrets.schema.json'
        metadata = [ordered]@{
            version = 2
            description = 'Preencha as credenciais abaixo. O bootstrap aplica somente a credencial ativa e validada de cada provedor.'
            notes = @(
                'Use credentials para armazenar varias chaves por provedor.',
                'activeCredential aponta para a chave atualmente aplicada.',
                'rotationOrder define a fila manual de troca.',
                'Os placeholders {{activeProviders.*}} e {{providers.*}} resolvem a credencial ativa validada.'
            )
        }
        providers = $providers
        targets = [ordered]@{
            userEnv = [ordered]@{
                ANTHROPIC_API_KEY = '{{activeProviders.anthropic.apiKey}}'
                OPENAI_API_KEY = '{{activeProviders.openai.apiKey}}'
                OPENAI_BASE_URL = '{{activeProviders.openai.baseUrl}}'
                OPENAI_ORGANIZATION = '{{activeProviders.openai.organizationId}}'
                GEMINI_API_KEY = '{{activeProviders.google.apiKey}}'
                GOOGLE_API_KEY = '{{activeProviders.google.apiKey}}'
                XAI_API_KEY = '{{activeProviders.xai.apiKey}}'
                XAI_BASE_URL = '{{activeProviders.xai.baseUrl}}'
                OPENROUTER_API_KEY = '{{activeProviders.openrouter.apiKey}}'
                OPENROUTER_BASE_URL = '{{activeProviders.openrouter.baseUrl}}'
                GITHUB_TOKEN = '{{activeProviders.github.token}}'
                GH_TOKEN = '{{activeProviders.github.token}}'
                MOONSHOT_API_KEY = '{{activeProviders.moonshot.apiKey}}'
                MOONSHOT_BASE_URL = '{{activeProviders.moonshot.baseUrl}}'
                DEEPSEEK_API_KEY = '{{activeProviders.deepseek.apiKey}}'
                DEEPSEEK_BASE_URL = '{{activeProviders.deepseek.baseUrl}}'
                BONSAI_TOKEN = '{{activeProviders.bonsai.token}}'
            }
            claudeCode = [ordered]@{
                env = [ordered]@{
                    ANTHROPIC_API_KEY = '{{activeProviders.anthropic.apiKey}}'
                    OPENAI_API_KEY = '{{activeProviders.openai.apiKey}}'
                    OPENAI_BASE_URL = '{{activeProviders.openai.baseUrl}}'
                    OPENAI_ORGANIZATION = '{{activeProviders.openai.organizationId}}'
                    GEMINI_API_KEY = '{{activeProviders.google.apiKey}}'
                    GOOGLE_API_KEY = '{{activeProviders.google.apiKey}}'
                    XAI_API_KEY = '{{activeProviders.xai.apiKey}}'
                    XAI_BASE_URL = '{{activeProviders.xai.baseUrl}}'
                    OPENROUTER_API_KEY = '{{activeProviders.openrouter.apiKey}}'
                    OPENROUTER_BASE_URL = '{{activeProviders.openrouter.baseUrl}}'
                    GITHUB_TOKEN = '{{activeProviders.github.token}}'
                    GH_TOKEN = '{{activeProviders.github.token}}'
                    MOONSHOT_API_KEY = '{{activeProviders.moonshot.apiKey}}'
                    MOONSHOT_BASE_URL = '{{activeProviders.moonshot.baseUrl}}'
                    DEEPSEEK_API_KEY = '{{activeProviders.deepseek.apiKey}}'
                    DEEPSEEK_BASE_URL = '{{activeProviders.deepseek.baseUrl}}'
                    BONSAI_TOKEN = '{{activeProviders.bonsai.token}}'
                }
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            claudeDesktop = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            cursor = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            windsurf = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        disabled = $true
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                        alwaysAllow = @()
                    }
                }
            }
            trae = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            openCode = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        type = 'local'
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            vsCode = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            roo = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        disabled = $true
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                        alwaysAllow = @()
                    }
                }
            }
            cline = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        disabled = $true
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                        alwaysAllow = @()
                    }
                }
            }
            continue = [ordered]@{
                env = [ordered]@{
                    ANTHROPIC_API_KEY = '{{activeProviders.anthropic.apiKey}}'
                    OPENAI_API_KEY = '{{activeProviders.openai.apiKey}}'
                    OPENAI_BASE_URL = '{{activeProviders.openai.baseUrl}}'
                    OPENAI_ORGANIZATION = '{{activeProviders.openai.organizationId}}'
                    GEMINI_API_KEY = '{{activeProviders.google.apiKey}}'
                    GOOGLE_API_KEY = '{{activeProviders.google.apiKey}}'
                    GITHUB_TOKEN = '{{activeProviders.github.token}}'
                    OPENROUTER_API_KEY = '{{activeProviders.openrouter.apiKey}}'
                    OPENROUTER_BASE_URL = '{{activeProviders.openrouter.baseUrl}}'
                    DEEPSEEK_API_KEY = '{{activeProviders.deepseek.apiKey}}'
                    DEEPSEEK_BASE_URL = '{{activeProviders.deepseek.baseUrl}}'
                    MOONSHOT_API_KEY = '{{activeProviders.moonshot.apiKey}}'
                    MOONSHOT_BASE_URL = '{{activeProviders.moonshot.baseUrl}}'
                }
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            zed = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            zCode = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        enabled = $false
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                    }
                }
            }
            openClaw = [ordered]@{
                mcpServers = [ordered]@{
                    github = [ordered]@{
                        disabled = $true
                        command = 'npx'
                        args = @('-y', '@modelcontextprotocol/server-github')
                        env = [ordered]@{
                            GITHUB_TOKEN = '{{activeProviders.github.token}}'
                        }
                        alwaysAllow = @()
                    }
                }
            }
            comet = [ordered]@{
            }
        }
    }
}

function Normalize-BootstrapSecretsData {
    param($Secrets)

    $template = Get-BootstrapSecretsTemplate
    $normalized = ConvertTo-BootstrapHashtable -InputObject $Secrets
    if (-not ($normalized -is [hashtable])) {
        $normalized = @{}
    }

    $metadata = [ordered]@{
        version = 2
        description = [string]$template.metadata.description
        notes = @($template.metadata.notes)
    }
    if ($normalized.ContainsKey('metadata') -and ($normalized['metadata'] -is [hashtable])) {
        if (-not [string]::IsNullOrWhiteSpace([string]$normalized['metadata']['description'])) {
            $metadata.description = [string]$normalized['metadata']['description']
        }
        if ($normalized['metadata'].ContainsKey('notes') -and ($normalized['metadata']['notes'] -is [System.Collections.IEnumerable])) {
            $notes = @()
            foreach ($item in @($normalized['metadata']['notes'])) {
                $value = [string]$item
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $notes += @($value)
                }
            }
            if ($notes.Count -gt 0) {
                $metadata.notes = @($notes)
            }
        }
    }

    $providersCurrent = if ($normalized.ContainsKey('providers') -and ($normalized['providers'] -is [hashtable])) { $normalized['providers'] } else { @{} }
    $providers = [ordered]@{}
    foreach ($providerName in @($template.providers.Keys + $providersCurrent.Keys | Select-Object -Unique)) {
        $providerCurrent = if ($providersCurrent.Contains($providerName)) { $providersCurrent[$providerName] } else { $null }
        $providers[$providerName] = Convert-BootstrapSecretsProviderDefinition -ProviderName ([string]$providerName) -ProviderData $providerCurrent
    }

    $targetsCurrent = if ($normalized.ContainsKey('targets') -and ($normalized['targets'] -is [hashtable])) { $normalized['targets'] } else { @{} }
    $targets = Merge-BootstrapData -Defaults $template.targets -Current $targetsCurrent

    return [ordered]@{
        '$schema' = [string]$template['$schema']
        metadata = $metadata
        providers = $providers
        targets = ConvertTo-BootstrapHashtable -InputObject $targets
    }
}

function Get-BootstrapSecretValueByPath {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $current = $Root
    foreach ($segment in @($Path -split '\.')) {
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
            continue
        }
        if ($current -is [pscustomobject]) {
            $property = $current.PSObject.Properties[$segment]
            if ($null -eq $property) { return $null }
            $current = $property.Value
            continue
        }
        return $null
    }
    return $current
}

function Resolve-BootstrapSecretTemplates {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Value,
        [Parameter(Mandatory = $true)]$SecretsData
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [string]) {
        return [regex]::Replace($Value, '\{\{([^}]+)\}\}', {
            param($match)
            $path = $match.Groups[1].Value.Trim()
            $resolved = Get-BootstrapSecretValueByPath -Root $SecretsData -Path $path
            if ($null -eq $resolved) { return '' }
            return [string]$resolved
        })
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = Resolve-BootstrapSecretTemplates -Value $Value[$key] -SecretsData $SecretsData
        }
        return $result
    }

    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = Resolve-BootstrapSecretTemplates -Value $property.Value -SecretsData $SecretsData
        }
        return $result
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += @(Resolve-BootstrapSecretTemplates -Value $item -SecretsData $SecretsData)
        }
        return ,@($items)
    }

    return $Value
}

function Get-BootstrapActiveProviders {
    param(
        [Parameter(Mandatory = $true)]$SecretsData,
        [switch]$RequirePassedValidation
    )

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData
    $catalog = Get-BootstrapSecretsProviderCatalog
    $result = [ordered]@{}

    foreach ($providerName in @($normalized.providers.Keys)) {
        $provider = ConvertTo-BootstrapHashtable -InputObject $normalized.providers[$providerName]
        if (-not ($provider -is [hashtable])) { continue }

        $activeCredential = [string]$provider['activeCredential']
        if ([string]::IsNullOrWhiteSpace($activeCredential)) { continue }
        if (-not ($provider.ContainsKey('credentials') -and ($provider['credentials'] -is [hashtable]) -and $provider['credentials'].Contains($activeCredential))) { continue }

        $credential = ConvertTo-BootstrapHashtable -InputObject $provider['credentials'][$activeCredential]
        if (-not ($credential -is [hashtable])) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$credential['secret'])) { continue }

        $validationState = if ($credential.ContainsKey('validation') -and ($credential['validation'] -is [hashtable])) { [string]$credential['validation']['state'] } else { 'unknown' }
        if ($RequirePassedValidation -and ($validationState -ne 'passed')) {
            continue
        }

        $providerMeta = if ($catalog.Contains($providerName)) { $catalog[$providerName] } else { @{} }
        $secretKind = if (-not [string]::IsNullOrWhiteSpace([string]$credential['secretKind'])) { [string]$credential['secretKind'] } elseif ($providerMeta.ContainsKey('secretKind')) { [string]$providerMeta['secretKind'] } else { 'secret' }

        $active = [ordered]@{
            credentialId = $activeCredential
            displayName = [string]$credential['displayName']
        }
        if ($provider.ContainsKey('defaults') -and ($provider['defaults'] -is [hashtable])) {
            foreach ($key in $provider['defaults'].Keys) {
                $value = [string]$provider['defaults'][$key]
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $active[$key] = $value
                }
            }
        }
        foreach ($key in $credential.Keys) {
            if ($key -in @('displayName', 'secret', 'secretKind', 'validation')) { continue }
            $value = [string]$credential[$key]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $active[$key] = $value
            }
        }

        switch ($secretKind) {
            'apiKey' { $active['apiKey'] = [string]$credential['secret'] }
            'token' { $active['token'] = [string]$credential['secret'] }
            default { $active['secret'] = [string]$credential['secret'] }
        }

        $result[$providerName] = $active
    }

    return $result
}

function Add-BootstrapImportedCredential {
    param(
        [Parameter(Mandatory = $true)][hashtable]$SecretsData,
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Secret
    )

    if ([string]::IsNullOrWhiteSpace($Secret)) { return $SecretsData }

    if (-not $SecretsData.ContainsKey('providers') -or -not ($SecretsData['providers'] -is [System.Collections.IDictionary])) {
        $SecretsData['providers'] = @{}
    }

    if (-not $SecretsData['providers'].Contains($ProviderName) -or -not ($SecretsData['providers'][$ProviderName] -is [System.Collections.IDictionary])) {
        $SecretsData['providers'][$ProviderName] = Get-BootstrapSecretsProviderDefinitionTemplate -ProviderName $ProviderName
    }

    $provider = ConvertTo-BootstrapHashtable -InputObject $SecretsData['providers'][$ProviderName]
    if (-not $provider.ContainsKey('credentials') -or -not ($provider['credentials'] -is [hashtable])) {
        $provider['credentials'] = [ordered]@{}
    }

    foreach ($existingId in $provider['credentials'].Keys) {
        $existingCredential = ConvertTo-BootstrapHashtable -InputObject $provider['credentials'][$existingId]
        if (($existingCredential -is [hashtable]) -and ([string]$existingCredential['secret'] -eq $Secret)) {
            return $SecretsData
        }
    }

    $catalog = Get-BootstrapSecretsProviderCatalog
    $defaultSecretKind = if ($catalog.Contains($ProviderName)) { [string]$catalog[$ProviderName]['secretKind'] } else { 'secret' }
    $credentialId = New-BootstrapSecretCredentialId -ProviderName $ProviderName -Label $DisplayName -ExistingIds @($provider['credentials'].Keys)
    $provider['credentials'][$credentialId] = [ordered]@{
        displayName = if ([string]::IsNullOrWhiteSpace($DisplayName)) { 'Imported' } else { $DisplayName.Trim() }
        secret = $Secret
        secretKind = $defaultSecretKind
        validation = New-BootstrapSecretValidationState
    }

    if (-not $provider.ContainsKey('rotationOrder') -or -not ($provider['rotationOrder'] -is [System.Collections.IEnumerable])) {
        $provider['rotationOrder'] = @()
    }
    $provider['rotationOrder'] = @($provider['rotationOrder']) + @($credentialId)
    $SecretsData['providers'][$ProviderName] = Convert-BootstrapSecretsProviderDefinition -ProviderName $ProviderName -ProviderData $provider
    return $SecretsData
}

function Get-BootstrapSecretsProviderNameFromHeading {
    param([string]$Heading)

    if ([string]::IsNullOrWhiteSpace($Heading)) { return $null }
    $normalizedHeading = $Heading.ToLowerInvariant()
    $catalog = Get-BootstrapSecretsProviderCatalog
    foreach ($providerName in $catalog.Keys) {
        foreach ($alias in @($catalog[$providerName]['aliases'])) {
            if ($normalizedHeading -like "*$alias*") {
                return $providerName
            }
        }
    }
    return $null
}

function Get-BootstrapSecretsTokenMatches {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $catalog = Get-BootstrapSecretsProviderCatalog
    if (-not $catalog.Contains($ProviderName)) { return @() }

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in @($catalog[$ProviderName]['tokenPatterns'])) {
        foreach ($match in [regex]::Matches($Text, $pattern)) {
            $value = [string]$match.Value
            if (-not [string]::IsNullOrWhiteSpace($value) -and -not $tokens.Contains($value)) {
                $tokens.Add($value)
            }
        }
    }

    return @($tokens.ToArray())
}

function Import-BootstrapSecretsText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)]$SecretsData
    )

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData
    $currentProvider = $null
    $lines = @($Text -split "`r?`n")

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^#{1,6}\s+(.+)$') {
            $currentProvider = Get-BootstrapSecretsProviderNameFromHeading -Heading ([string]$matches[1])
            continue
        }
        if (-not $currentProvider) { continue }
        if ($trimmed -match '^https?://') { continue }
        if ($trimmed -match '^[A-Za-z]:\\') { continue }

        if (($currentProvider -eq 'openai') -and ($trimmed -match '(org-[A-Za-z0-9]+)')) {
            $normalized.providers.openai.defaults.organizationId = [string]$matches[1]
        }

        $displayName = 'Imported'
        $candidateText = $trimmed
        if ($trimmed.StartsWith('|')) {
            $cells = @($trimmed.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
            if ($cells.Count -gt 0) {
                if ($cells[0] -match '^(servi[cç]o|service|chave|key|observa)') { continue }
                $displayName = if ([string]::IsNullOrWhiteSpace($cells[0])) { 'Imported' } else { $cells[0] }
                $candidateText = [string]::Join(' ', $cells)
            }
        } elseif ($trimmed -match '^([^:]+):\s+') {
            $displayName = [string]$matches[1]
        } elseif ($trimmed -match '^([^-]+)\s+-\s+') {
            $displayName = [string]$matches[1]
        }

        foreach ($token in @(Get-BootstrapSecretsTokenMatches -ProviderName $currentProvider -Text $candidateText)) {
            $normalized = Add-BootstrapImportedCredential -SecretsData $normalized -ProviderName $currentProvider -DisplayName $displayName -Secret $token
        }
    }

    return (Normalize-BootstrapSecretsData -Secrets $normalized)
}

function Get-BootstrapSecretsListEntries {
    param([Parameter(Mandatory = $true)]$SecretsData)

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData
    $entries = @()

    foreach ($providerName in ($normalized.providers.Keys | Sort-Object)) {
        $provider = ConvertTo-BootstrapHashtable -InputObject $normalized.providers[$providerName]
        if (-not ($provider -is [hashtable])) { continue }

        $orderedIds = New-Object System.Collections.Generic.List[string]
        foreach ($credentialId in @($provider['rotationOrder'])) {
            $value = [string]$credentialId
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if (-not $orderedIds.Contains($value)) { $orderedIds.Add($value) }
        }
        if ($provider.ContainsKey('credentials') -and ($provider['credentials'] -is [hashtable])) {
            foreach ($credentialId in $provider['credentials'].Keys) {
                if (-not $orderedIds.Contains([string]$credentialId)) {
                    $orderedIds.Add([string]$credentialId)
                }
            }
        }

        $order = 0
        foreach ($credentialId in $orderedIds) {
            if (-not ($provider.ContainsKey('credentials') -and ($provider['credentials'] -is [hashtable]) -and $provider['credentials'].Contains($credentialId))) { continue }
            $order += 1
            $credential = ConvertTo-BootstrapHashtable -InputObject $provider['credentials'][$credentialId]
            $validation = if ($credential.ContainsKey('validation') -and ($credential['validation'] -is [hashtable])) { $credential['validation'] } else { @{} }
            $entries += [pscustomobject]@{
                provider = [string]$providerName
                id = [string]$credentialId
                displayName = [string]$credential['displayName']
                active = ([string]$provider['activeCredential'] -eq [string]$credentialId)
                order = $order
                validationState = [string]$validation['state']
                validationMessage = [string]$validation['message']
            }
        }
    }

    return @($entries)
}

function Get-BootstrapResolvedSecretsTargets {
    param(
        [Parameter(Mandatory = $true)]$SecretsData,
        [switch]$IncludeManagedMcps
    )

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData
    $activeProviders = Get-BootstrapActiveProviders -SecretsData $normalized -RequirePassedValidation
    $context = [ordered]@{
        metadata = $normalized['metadata']
        targets = $normalized['targets']
        activeProviders = $activeProviders
        providers = $activeProviders
    }

    $resolvedTargets = ConvertTo-BootstrapHashtable -InputObject (Resolve-BootstrapSecretTemplates -Value $normalized['targets'] -SecretsData $context)
    if ($resolvedTargets -is [hashtable]) {
        $hasGithubToken = $activeProviders.Contains('github') -and -not [string]::IsNullOrWhiteSpace([string]$activeProviders['github']['token'])
        foreach ($targetName in @('vsCode', 'continue')) {
            if ($resolvedTargets.ContainsKey($targetName) -and ($resolvedTargets[$targetName] -is [hashtable])) {
                $target = ConvertTo-BootstrapHashtable -InputObject $resolvedTargets[$targetName]
                if ($target.ContainsKey('mcpServers') -and ($target['mcpServers'] -is [hashtable]) -and $target['mcpServers'].ContainsKey('github')) {
                    $githubServer = ConvertTo-BootstrapHashtable -InputObject $target['mcpServers']['github']
                    $githubServer['enabled'] = $hasGithubToken
                    $target['mcpServers']['github'] = $githubServer
                    $resolvedTargets[$targetName] = $target
                }
            }
        }

        if ($IncludeManagedMcps) {
            $managedProviders = Get-BootstrapManagedMcpProviders -SecretsData $normalized
            $resolvedTargets = Merge-BootstrapManagedMcpTargets -ResolvedTargets $resolvedTargets -ManagedProviders $managedProviders
        }
    }

    return $resolvedTargets
}

function Get-BootstrapSecretsDiagnostics {
    param([Parameter(Mandatory = $true)]$SecretsData)

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData
    $knownTargets = Get-BootstrapSecretsKnownTargets
    $warnings = @()
    $unknownTargets = @()
    $invalidTargets = @()

    if (-not ($normalized['providers'] -is [System.Collections.IDictionary])) {
        $warnings += @('providers deve ser um objeto JSON.')
    }
    if (-not ($normalized['targets'] -is [System.Collections.IDictionary])) {
        $warnings += @('targets deve ser um objeto JSON.')
    } else {
        foreach ($targetName in $normalized['targets'].Keys) {
            if ($knownTargets -notcontains [string]$targetName) {
                $unknownTargets += @([string]$targetName)
                continue
            }
            if (-not ($normalized['targets'][$targetName] -is [System.Collections.IDictionary])) {
                $invalidTargets += @([string]$targetName)
            }
        }
    }

    if ($unknownTargets.Count -gt 0) {
        $warnings += @("Targets desconhecidos no manifesto: $([string]::Join(', ', $unknownTargets))")
    }
    if ($invalidTargets.Count -gt 0) {
        $warnings += @("Targets invalidos (esperado objeto JSON): $([string]::Join(', ', $invalidTargets))")
    }
    if ($normalized['targets'] -is [System.Collections.IDictionary] -and $normalized['targets'].Contains('comet') -and ($normalized['targets']['comet'] -is [System.Collections.IDictionary])) {
        if (@($normalized['targets']['comet'].Keys).Count -gt 0) {
            $warnings += @('Comet: sem suporte a MCP por arquivo; ignore este target ou deixe-o vazio.')
        }
    }

    return [ordered]@{
        warnings = @($warnings)
        unknownTargets = @($unknownTargets)
        invalidTargets = @($invalidTargets)
    }
}

function Get-BootstrapSecretsData {
    $path = Get-BootstrapSecretsPath
    $current = $null
    $created = $false

    if (Test-Path $path) {
        try {
            $current = Get-Content -Path $path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log "Falha ao ler bootstrap-secrets.json. O arquivo sera reformatado com os defaults atuais: $path" 'WARN'
        }
    }

    if (-not $current) {
        $current = @{}
        $created = $true
    }

    $normalized = Normalize-BootstrapSecretsData -Secrets $current
    Write-BootstrapJsonFile -Path $path -Value $normalized

    return [ordered]@{
        Path = $path
        Data = $normalized
        Created = $created
    }
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
    $json = [string]((ConvertTo-BootstrapObjectGraph -InputObject $merged) | ConvertTo-Json -Depth 12)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($settingsPath, $json, $utf8)
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
    $catalog['vscode'] = New-BootstrapComponentDefinition -Name 'vscode' -Description 'VS Code estável.' -DependsOn @('system-core') -Kind 'winget' -Data @{ Id = 'Microsoft.VisualStudioCode'; DisplayName = 'Visual Studio Code'; AllowFailureWhenNotAdmin = $true }
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
    $catalog['bootstrap-secrets'] = New-BootstrapComponentDefinition -Name 'bootstrap-secrets' -Description 'Cria e aplica manifesto local de chaves, tokens e MCPs.' -Kind 'bootstrap-secrets'
    $catalog['bootstrap-mcps'] = New-BootstrapComponentDefinition -Name 'bootstrap-mcps' -Description 'Instala dependencias locais dos MCPs gerenciados e registra o estado da automacao.' -DependsOn @('bootstrap-secrets', 'node-core', 'python-core') -Kind 'bootstrap-mcps'
    $catalog['vscode-extensions'] = New-BootstrapComponentDefinition -Name 'vscode-extensions' -Description 'Instala e configura extensões do VS Code e VS Code Insiders.' -DependsOn @('bootstrap-secrets', 'vscode', 'vscode-insiders') -Kind 'vscode-extensions'
    $catalog['claude-config'] = New-BootstrapComponentDefinition -Name 'claude-config' -Description 'Defaults e hooks do Claude Code.' -DependsOn @('git-core', 'claude-code', 'bootstrap-secrets') -Kind 'claude-config'
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

    $catalog['legacy'] = New-BootstrapProfileDefinition -Name 'legacy' -Description 'Replica o fluxo atual do script.' -Items @('git-core', 'node-core', 'java-core', 'imagemagick', 'sevenzip', 'python-core', 'opencode', 'claude-code', 'github-cli', 'chrome', 'google-app-desktop', 'notepadpp', 'claude-desktop', 'cursor', 'windsurf', 'warp', 'trae', 'opencode-desktop', 'vscode', 'vscode-insiders', 'wsl-ui', 'antigravity', 'autoclaw', 'perplexity', 'codex-installer', 'gemini-cli', 'bonsai-cli', 'grok-cli', 'qwen-code', 'copilot-cli', 'codex-cli', 'openclaw', 'bootstrap-secrets', 'bootstrap-mcps', 'vscode-extensions', 'claude-config', 'aider', 'goose', 'repo-gemini-cli')
    $catalog['base'] = New-BootstrapProfileDefinition -Name 'base' -Description 'Base universal para máquina nova.' -Items @('git-core', 'git-lfs', 'node-core', 'python-core', 'java-core', 'imagemagick', 'sevenzip', 'powershell', 'terminal', 'powertoys', 'github-cli', 'chrome', 'google-app-desktop', 'brave', 'notepadpp')
    $catalog['containers'] = New-BootstrapProfileDefinition -Name 'containers' -Description 'WSL e Docker.' -Items @('wsl-core', 'wsl-ui', 'docker')
    $catalog['ai'] = New-BootstrapProfileDefinition -Name 'ai' -Description 'Desktops e CLIs de IA.' -Items @('claude-desktop', 'claude-code', 'cursor', 'windsurf', 'warp', 'trae', 'opencode-desktop', 'vscode', 'vscode-insiders', 'antigravity', 'autoclaw', 'perplexity', 'codex-installer', 'ollama', 'cherry-studio', 'lm-studio', 'pinokio', 'zed', 'opencode', 'gemini-cli', 'bonsai-cli', 'grok-cli', 'qwen-code', 'copilot-cli', 'codex-cli', 'openclaw', 'bootstrap-secrets', 'bootstrap-mcps', 'vscode-extensions', 'claude-config', 'aider', 'goose', 'repo-gemini-cli')
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
        SecretsPath = $null
        SecretsSummary = $null
        McpStatePath = $null
        McpSummary = $null
        VsCodeExtensionsPath = $null
        VsCodeExtensionsSummary = $null
        PreflightDone = $false
        PreflightSummary = $null
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
        Invoke-WebRequestWithRetry -Uri $downloadUrl -OutFile $zipPath -OperationName 'download do Steam Deck Tools'
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

    $json = [string]((ConvertTo-BootstrapObjectGraph -InputObject $Value) | ConvertTo-Json -Depth 12)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Remove-BootstrapJsonComments {
    param([Parameter(Mandatory = $true)][string]$Text)

    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $escape = $false
    $inLineComment = $false
    $inBlockComment = $false

    for ($index = 0; $index -lt $Text.Length; $index++) {
        $char = $Text[$index]
        $next = if (($index + 1) -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($char -eq "`r" -or $char -eq "`n") {
                $inLineComment = $false
                [void]$builder.Append($char)
            }
            continue
        }

        if ($inBlockComment) {
            if ($char -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $index += 1
            }
            continue
        }

        if ($inString) {
            [void]$builder.Append($char)
            if ($escape) {
                $escape = $false
            } elseif ($char -eq '\') {
                $escape = $true
            } elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($char -eq '"') {
            $inString = $true
            [void]$builder.Append($char)
            continue
        }

        if ($char -eq '/' -and $next -eq '/') {
            $inLineComment = $true
            $index += 1
            continue
        }

        if ($char -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $index += 1
            continue
        }

        [void]$builder.Append($char)
    }

    return $builder.ToString()
}

function Remove-BootstrapJsonTrailingCommas {
    param([Parameter(Mandatory = $true)][string]$Text)

    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $escape = $false

    for ($index = 0; $index -lt $Text.Length; $index++) {
        $char = $Text[$index]

        if ($inString) {
            [void]$builder.Append($char)
            if ($escape) {
                $escape = $false
            } elseif ($char -eq '\') {
                $escape = $true
            } elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($char -eq '"') {
            $inString = $true
            [void]$builder.Append($char)
            continue
        }

        if ($char -eq ',') {
            $lookAhead = $index + 1
            while ($lookAhead -lt $Text.Length -and [char]::IsWhiteSpace($Text[$lookAhead])) {
                $lookAhead += 1
            }

            if ($lookAhead -lt $Text.Length -and $Text[$lookAhead] -in @('}', ']')) {
                continue
            }
        }

        [void]$builder.Append($char)
    }

    return $builder.ToString()
}

function ConvertFrom-BootstrapJsonText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $withoutComments = Remove-BootstrapJsonComments -Text $Text
    $sanitized = Remove-BootstrapJsonTrailingCommas -Text $withoutComments
    return ($sanitized | ConvertFrom-Json -ErrorAction Stop)
}

function Read-BootstrapJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    return (ConvertTo-BootstrapHashtable -InputObject (ConvertFrom-BootstrapJsonText -Text (Get-Content -Path $Path -Raw -Encoding utf8)))
}

function Ensure-BootstrapNamedMap {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Parent,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Parent.ContainsKey($Name) -or -not ($Parent[$Name] -is [hashtable])) {
        $Parent[$Name] = @{}
    }
    return $Parent[$Name]
}

function Remove-BootstrapEmptyNamedMap {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Parent,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Parent.ContainsKey($Name) -and ($Parent[$Name] -is [hashtable]) -and ($Parent[$Name].Count -eq 0)) {
        $Parent.Remove($Name) | Out-Null
        return $true
    }
    return $false
}

function Set-BootstrapNonEmptyStringValues {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Target,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    foreach ($key in $Values.Keys) {
        $value = [string]$Values[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $Target[[string]$key] = $value
    }
}

function Get-BootstrapClaudeDesktopConfigPath {
    return (Join-Path (Get-BootstrapAppDataPath) 'Claude\claude_desktop_config.json')
}

function Get-BootstrapCursorMcpConfigPath {
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($userHome) { Join-Path $userHome '.cursor\mcp.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Cursor\mcp.json' })
    ) -DefaultPath $(if ($userHome) { Join-Path $userHome '.cursor\mcp.json' } else { $null }))
}

function Get-BootstrapWindsurfMcpConfigPath {
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($appDataPath) { Join-Path $appDataPath 'Codeium\Windsurf\mcp_config.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Windsurf\mcp.json' }),
        $(if ($userHome) { Join-Path $userHome '.codeium\windsurf\mcp_config.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Windsurf\User\settings.json' })
    ) -DefaultPath $(if ($appDataPath) { Join-Path $appDataPath 'Codeium\Windsurf\mcp_config.json' } else { $null }))
}

function Get-BootstrapTraeMcpConfigPath {
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($appDataPath) { Join-Path $appDataPath 'Trae\User\mcp.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Trae\User\settings.json' })
    ) -DefaultPath $(if ($appDataPath) { Join-Path $appDataPath 'Trae\User\mcp.json' } else { $null }))
}

function Get-BootstrapOpenCodeConfigPath {
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($userHome) { Join-Path $userHome '.config\opencode\opencode.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'OpenCode\opencode.json' })
    ) -DefaultPath $(if ($userHome) { Join-Path $userHome '.config\opencode\opencode.json' } else { $null }))
}

function Test-BootstrapVsCodeStableInstalled {
    $localAppDataPath = Get-BootstrapLocalAppDataPath
    $programFilesX86 = ${env:ProgramFiles(x86)}
    $candidates = @(
        $(if ($localAppDataPath) { Join-Path $localAppDataPath 'Programs\Microsoft VS Code\Code.exe' }),
        $(if ($localAppDataPath) { Join-Path $localAppDataPath 'Programs\Microsoft VS Code\bin\code.cmd' }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe' }),
        $(if ($programFilesX86) { Join-Path $programFilesX86 'Microsoft VS Code\Code.exe' })
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $true
        }
    }

    return $false
}

function Test-BootstrapVsCodeInsidersInstalled {
    $localAppDataPath = Get-BootstrapLocalAppDataPath
    $programFilesX86 = ${env:ProgramFiles(x86)}
    $candidates = @(
        $(if ($localAppDataPath) { Join-Path $localAppDataPath 'Programs\Microsoft VS Code Insiders\Code - Insiders.exe' }),
        $(if ($localAppDataPath) { Join-Path $localAppDataPath 'Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd' }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft VS Code Insiders\Code - Insiders.exe' }),
        $(if ($programFilesX86) { Join-Path $programFilesX86 'Microsoft VS Code Insiders\Code - Insiders.exe' })
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $true
        }
    }

    return $false
}

function Resolve-BootstrapVsCodeCliPath {
    param([Parameter(Mandatory = $true)][ValidateSet('stable', 'insiders')][string]$Channel)

    $localAppDataPath = Get-BootstrapLocalAppDataPath
    $programFilesX86 = ${env:ProgramFiles(x86)}
    $commandName = if ($Channel -eq 'insiders') { 'code-insiders' } else { 'code' }
    $candidates = @()

    if ($Channel -eq 'insiders') {
        $candidates += @(
            $(if ($localAppDataPath) { Join-Path $localAppDataPath 'Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd' }),
            $(if ($localAppDataPath) { Join-Path $localAppDataPath 'Programs\Microsoft VS Code Insiders\bin\code-insiders' }),
            $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft VS Code Insiders\bin\code-insiders.cmd' }),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Microsoft VS Code Insiders\bin\code-insiders.cmd' })
        )
    } else {
        $candidates += @(
            $(if ($localAppDataPath) { Join-Path $localAppDataPath 'Programs\Microsoft VS Code\bin\code.cmd' }),
            $(if ($localAppDataPath) { Join-Path $localAppDataPath 'Programs\Microsoft VS Code\bin\code' }),
            $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd' }),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'Microsoft VS Code\bin\code.cmd' })
        )
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    $resolved = Resolve-CommandPath -Name $commandName
    if ($resolved) {
        return $resolved
    }

    return $null
}

function Get-BootstrapVsCodeSettingsPath {
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($appDataPath) { Join-Path $appDataPath 'Code\User\settings.json' }),
        $(if ($userHome) { Join-Path $userHome '.vscode\settings.json' })
    ) -DefaultPath $(if ($appDataPath) { Join-Path $appDataPath 'Code\User\settings.json' } else { $null }))
}

function Get-BootstrapVsCodeInsidersSettingsPath {
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($appDataPath) { Join-Path $appDataPath 'Code - Insiders\User\settings.json' })
    ) -DefaultPath $(if ($appDataPath) { Join-Path $appDataPath 'Code - Insiders\User\settings.json' } else { $null }))
}

function Get-BootstrapVsCodeMcpConfigPath {
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    $agentsPath = if ($appDataPath) { Join-Path $appDataPath 'Agents - Insiders\User\mcp.json' } else { $null }
    $insidersPath = if ($appDataPath) { Join-Path $appDataPath 'Code - Insiders\User\mcp.json' } else { $null }
    $stablePath = if ($appDataPath) { Join-Path $appDataPath 'Code\User\mcp.json' } else { $null }
    $workspacePath = if ($userHome) { Join-Path $userHome '.vscode\mcp.json' } else { $null }

    foreach ($candidate in @($agentsPath, $insidersPath, $stablePath, $workspacePath)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    if (Test-BootstrapVsCodeInsidersInstalled) {
        foreach ($candidate in @($agentsPath, $insidersPath)) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $parent = Split-Path -Path $candidate -Parent
            if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path $parent)) {
                return $candidate
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($agentsPath)) {
            return $agentsPath
        }
        return $insidersPath
    }

    foreach ($candidate in @($agentsPath, $insidersPath, $stablePath, $workspacePath)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $parent = Split-Path -Path $candidate -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path $parent)) {
            return $candidate
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($stablePath)) {
        return $stablePath
    }
    if (-not [string]::IsNullOrWhiteSpace($agentsPath)) {
        return $agentsPath
    }
    return $workspacePath
}

function Get-BootstrapRooMcpConfigPath {
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($userHome) { Join-Path $userHome '.roo\mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Code\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Code\User\globalStorage\rooveterinaryinc.roo-code\settings\mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Code - Insiders\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Code - Insiders\User\globalStorage\rooveterinaryinc.roo-code\settings\mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Agents - Insiders\User\globalStorage\rooveterinaryinc.roo-cline\settings\mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Agents - Insiders\User\globalStorage\rooveterinaryinc.roo-code\settings\mcp_settings.json' })
    ) -DefaultPath $(if ($userHome) { Join-Path $userHome '.roo\mcp_settings.json' } else { $null }))
}

function Get-BootstrapClineMcpConfigPath {
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($appDataPath) { Join-Path $appDataPath 'Code\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Code - Insiders\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Cursor\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Windsurf\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'Agents - Insiders\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json' })
    ) -DefaultPath $(if ($appDataPath) { Join-Path $appDataPath 'Code\User\globalStorage\saoudrizwan.claude-dev\settings\cline_mcp_settings.json' } else { $null }))
}

function Get-BootstrapZedConfigPath {
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($appDataPath) { Join-Path $appDataPath 'Zed\settings.json' }),
        $(if ($userHome) { Join-Path $userHome '.config\zed\settings.json' })
    ) -DefaultPath $(if ($appDataPath) { Join-Path $appDataPath 'Zed\settings.json' } else { $null }))
}

function Get-BootstrapZCodeStorePath {
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($appDataPath) { Join-Path $appDataPath 'ai.z.zcode\store.json' })
    ) -DefaultPath $(if ($appDataPath) { Join-Path $appDataPath 'ai.z.zcode\store.json' } else { $null }))
}

function Get-BootstrapOpenClawConfigPath {
    $userHome = Get-BootstrapUserHomePath
    $appDataPath = Get-BootstrapAppDataPath
    return (Get-BootstrapPreferredFilePath -Candidates @(
        $(if ($userHome) { Join-Path $userHome '.openclaw\openclaw.json' }),
        $(if ($appDataPath) { Join-Path $appDataPath 'clawdbot\clawdbot.json5' })
    ) -DefaultPath $(if ($userHome) { Join-Path $userHome '.openclaw\openclaw.json' } else { $null }))
}

function Test-BootstrapSecretsProviderCredential {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][hashtable]$ProviderDefinition,
        [Parameter(Mandatory = $true)][string]$CredentialId,
        [Parameter(Mandatory = $true)][hashtable]$Credential
    )

    $catalog = Get-BootstrapSecretsProviderCatalog
    $checkedAt = (Get-Date).ToString('o')
    $providerMeta = if ($catalog.Contains($ProviderName)) { $catalog[$ProviderName] } else { @{} }
    $validationKind = if ($providerMeta.ContainsKey('validationKind')) { [string]$providerMeta['validationKind'] } else { 'unsupported' }
    $secret = [string]$Credential['secret']
    if ([string]::IsNullOrWhiteSpace($secret)) {
        return (New-BootstrapSecretValidationState -State 'failed' -CheckedAt $checkedAt -Message 'secret vazio')
    }

    $baseUrl = ''
    if ($Credential.ContainsKey('baseUrl') -and -not [string]::IsNullOrWhiteSpace([string]$Credential['baseUrl'])) {
        $baseUrl = [string]$Credential['baseUrl']
    } elseif ($ProviderDefinition.ContainsKey('defaults') -and ($ProviderDefinition['defaults'] -is [hashtable]) -and -not [string]::IsNullOrWhiteSpace([string]$ProviderDefinition['defaults']['baseUrl'])) {
        $baseUrl = [string]$ProviderDefinition['defaults']['baseUrl']
    } elseif ($providerMeta.ContainsKey('defaults') -and ($providerMeta['defaults'] -is [hashtable]) -and -not [string]::IsNullOrWhiteSpace([string]$providerMeta['defaults']['baseUrl'])) {
        $baseUrl = [string]$providerMeta['defaults']['baseUrl']
    }

    $headers = @{}
    $uri = ''
    switch ($validationKind) {
        'anthropic' {
            $uri = 'https://api.anthropic.com/v1/models'
            $headers = @{
                'x-api-key' = $secret
                'anthropic-version' = '2023-06-01'
            }
        }
        'google' {
            $uri = 'https://generativelanguage.googleapis.com/v1beta/models?key=' + [Uri]::EscapeDataString($secret)
        }
        'github' {
            $uri = 'https://api.github.com/user'
            $headers = @{
                Authorization = "Bearer $secret"
                Accept = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2022-11-28'
                'User-Agent' = 'PhaseZero Bootstrap'
            }
        }
        'openaiCompatible' {
            if ([string]::IsNullOrWhiteSpace($baseUrl)) {
                return (New-BootstrapSecretValidationState -State 'failed' -CheckedAt $checkedAt -Message 'baseUrl ausente')
            }
            $uri = ($baseUrl.TrimEnd('/') + '/models')
            $headers = @{
                Authorization = "Bearer $secret"
            }
        }
        default {
            return (New-BootstrapSecretValidationState -State 'unsupported/manual-review' -CheckedAt $checkedAt -Message 'sem validador dedicado')
        }
    }

    try {
        $null = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
        return (New-BootstrapSecretValidationState -State 'passed' -CheckedAt $checkedAt -Message 'ok')
    } catch {
        return (New-BootstrapSecretValidationState -State 'failed' -CheckedAt $checkedAt -Message $_.Exception.Message)
    }
}

function Invoke-BootstrapSecretsValidation {
    param(
        [Parameter(Mandatory = $true)]$SecretsData,
        [switch]$ValidateAll
    )

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData

    foreach ($providerName in @($normalized.providers.Keys)) {
        $provider = ConvertTo-BootstrapHashtable -InputObject $normalized.providers[$providerName]
        if (-not ($provider -is [hashtable])) { continue }
        if (-not ($provider.ContainsKey('credentials') -and ($provider['credentials'] -is [hashtable]))) { continue }

        $credentialIds = @()
        if ($ValidateAll) {
            $credentialIds = @($provider['credentials'].Keys)
        } else {
            $activeCredential = [string]$provider['activeCredential']
            if (-not [string]::IsNullOrWhiteSpace($activeCredential) -and $provider['credentials'].Contains($activeCredential)) {
                $credentialIds = @($activeCredential)
            }
        }

        foreach ($credentialId in $credentialIds) {
            $credential = ConvertTo-BootstrapHashtable -InputObject $provider['credentials'][$credentialId]
            if (-not ($credential -is [hashtable])) { continue }
            $provider['credentials'][$credentialId]['validation'] = Test-BootstrapSecretsProviderCredential -ProviderName ([string]$providerName) -ProviderDefinition $provider -CredentialId ([string]$credentialId) -Credential $credential
        }

        $normalized.providers[$providerName] = Convert-BootstrapSecretsProviderDefinition -ProviderName ([string]$providerName) -ProviderData $provider
    }

    return $normalized
}

function Set-BootstrapSecretsActiveCredential {
    param(
        [Parameter(Mandatory = $true)]$SecretsData,
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][string]$CredentialId
    )

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData
    if (-not $normalized.providers.Contains($ProviderName)) {
        throw "Provider desconhecido: $ProviderName"
    }

    $provider = ConvertTo-BootstrapHashtable -InputObject $normalized.providers[$ProviderName]
    if (-not ($provider.ContainsKey('credentials') -and ($provider['credentials'] -is [hashtable]) -and $provider['credentials'].Contains($CredentialId))) {
        throw "Credencial desconhecida para ${ProviderName}: $CredentialId"
    }

    $credential = ConvertTo-BootstrapHashtable -InputObject $provider['credentials'][$CredentialId]
    $provider['credentials'][$CredentialId]['validation'] = Test-BootstrapSecretsProviderCredential -ProviderName $ProviderName -ProviderDefinition $provider -CredentialId $CredentialId -Credential $credential
    if ([string]$provider['credentials'][$CredentialId]['validation']['state'] -eq 'passed') {
        $provider['activeCredential'] = $CredentialId
    }

    $normalized.providers[$ProviderName] = Convert-BootstrapSecretsProviderDefinition -ProviderName $ProviderName -ProviderData $provider
    return $normalized
}

function Move-BootstrapSecretsToNextCredential {
    param(
        [Parameter(Mandatory = $true)]$SecretsData,
        [Parameter(Mandatory = $true)][string]$ProviderName
    )

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData
    if (-not $normalized.providers.Contains($ProviderName)) {
        throw "Provider desconhecido: $ProviderName"
    }

    $provider = ConvertTo-BootstrapHashtable -InputObject $normalized.providers[$ProviderName]
    if (-not ($provider.ContainsKey('credentials') -and ($provider['credentials'] -is [hashtable]))) {
        return $normalized
    }

    $rotationOrder = @($provider['rotationOrder'])
    $activeCredential = [string]$provider['activeCredential']
    $candidateIds = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($activeCredential) -and $provider['credentials'].Contains($activeCredential)) {
        $candidateIds.Add($activeCredential)
    }
    foreach ($credentialId in $rotationOrder) {
        $value = [string]$credentialId
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if (-not $candidateIds.Contains($value)) {
            $candidateIds.Add($value)
        }
    }
    foreach ($credentialId in $provider['credentials'].Keys) {
        if (-not $candidateIds.Contains([string]$credentialId)) {
            $candidateIds.Add([string]$credentialId)
        }
    }

    foreach ($credentialId in $candidateIds) {
        $credential = ConvertTo-BootstrapHashtable -InputObject $provider['credentials'][$credentialId]
        if (-not ($credential -is [hashtable])) { continue }

        $provider['credentials'][$credentialId]['validation'] = Test-BootstrapSecretsProviderCredential -ProviderName $ProviderName -ProviderDefinition $provider -CredentialId ([string]$credentialId) -Credential $credential
        $state = [string]$provider['credentials'][$credentialId]['validation']['state']
        if (($credentialId -eq $activeCredential) -and ($state -eq 'passed')) {
            $normalized.providers[$ProviderName] = Convert-BootstrapSecretsProviderDefinition -ProviderName $ProviderName -ProviderData $provider
            return $normalized
        }
        if (($credentialId -ne $activeCredential) -and ($state -eq 'passed')) {
            $provider['activeCredential'] = [string]$credentialId
            $normalized.providers[$ProviderName] = Convert-BootstrapSecretsProviderDefinition -ProviderName $ProviderName -ProviderData $provider
            return $normalized
        }
    }

    $normalized.providers[$ProviderName] = Convert-BootstrapSecretsProviderDefinition -ProviderName $ProviderName -ProviderData $provider
    return $normalized
}

function Test-BootstrapSecretsTargetHasApplicableValues {
    param($Target)

    $normalized = ConvertTo-BootstrapHashtable -InputObject $Target
    if (-not ($normalized -is [hashtable])) {
        return $false
    }

    foreach ($key in $normalized.Keys) {
        if ($key -eq 'env' -and ($normalized[$key] -is [hashtable])) {
            foreach ($envKey in $normalized[$key].Keys) {
                if (-not [string]::IsNullOrWhiteSpace([string]$normalized[$key][$envKey])) {
                    return $true
                }
            }
            continue
        }

        if ($key -eq 'mcpServers' -and ($normalized[$key] -is [hashtable])) {
            foreach ($serverName in $normalized[$key].Keys) {
                $server = ConvertTo-BootstrapHashtable -InputObject $normalized[$key][$serverName]
                if (-not ($server -is [hashtable])) { continue }
                if ($server.ContainsKey('enabled') -and (-not [bool]$server['enabled'])) { continue }
                if ($server.ContainsKey('disabled') -and [bool]$server['disabled']) { continue }
                return $true
            }
            continue
        }

        if ($normalized[$key] -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace([string]$normalized[$key])) {
                return $true
            }
        }
    }

    return $false
}

function Ensure-BootstrapUserEnvSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('userEnv') -or -not ($ResolvedTargets['userEnv'] -is [hashtable])) {
        return 0
    }

    $applied = 0
    foreach ($name in $ResolvedTargets['userEnv'].Keys) {
        $value = [string]$ResolvedTargets['userEnv'][$name]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        Set-UserEnvVar -Name ([string]$name) -Value $value
        $applied += 1
    }
    return $applied
}

function ConvertFrom-BootstrapRemoteBridgeServerDefinition {
    param([Parameter(Mandatory = $true)][hashtable]$ServerDefinition)

    if (-not $ServerDefinition.ContainsKey('command')) {
        return $null
    }

    $command = [string]$ServerDefinition['command']
    if (-not [string]::Equals($command, 'npx', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $args = Get-BootstrapNonEmptyStringArray -Values @($ServerDefinition['args'])
    if ($args.Count -lt 2) {
        return $null
    }
    if ($args[0] -ne '-y' -or $args[1] -ne 'mcp-remote@latest') {
        return $null
    }

    $url = ''
    $headers = [ordered]@{}
    $index = 2
    while ($index -lt $args.Count) {
        $token = [string]$args[$index]
        switch ($token) {
            '--http' {
                $index += 1
                if ($index -lt $args.Count) {
                    $url = [string]$args[$index]
                }
            }
            '--allow-http' {
            }
            '--header' {
                $index += 1
                if ($index -lt $args.Count) {
                    $headerLine = [string]$args[$index]
                    $parts = $headerLine -split ':\s*', 2
                    if ($parts.Count -eq 2) {
                        $headers[$parts[0]] = $parts[1]
                    }
                }
            }
            default {
                if ([string]::IsNullOrWhiteSpace($url) -and ($token -match '^[a-z]+://')) {
                    $url = $token
                }
            }
        }
        $index += 1
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        return $null
    }

    $remote = [ordered]@{
        url = $url
    }
    if ($headers.Count -gt 0) {
        $remote['headers'] = $headers
    }

    return $remote
}

function ConvertTo-BootstrapMcpServerEntry {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ServerDefinition,
        [Parameter(Mandatory = $true)][ValidateSet('standard', 'opencode', 'vscode', 'zed', 'zcode')][string]$Format
    )

    if ($ServerDefinition.ContainsKey('enabled') -and (-not [bool]$ServerDefinition['enabled'])) {
        return $null
    }
    if ($ServerDefinition.ContainsKey('disabled') -and [bool]$ServerDefinition['disabled']) {
        return $null
    }

    $effectiveDefinition = $ServerDefinition
    $remoteBridgeDefinition = ConvertFrom-BootstrapRemoteBridgeServerDefinition -ServerDefinition $ServerDefinition
    if (($remoteBridgeDefinition -is [System.Collections.IDictionary]) -and $Format -in @('vscode', 'zed', 'zcode')) {
        $effectiveDefinition = ConvertTo-BootstrapHashtable -InputObject $remoteBridgeDefinition
    }

    if ($Format -eq 'opencode') {
        $serverOut = @{}
        $type = ''
        if ($effectiveDefinition.ContainsKey('type')) {
            $type = [string]$effectiveDefinition['type']
        }
        if ([string]::IsNullOrWhiteSpace($type)) {
            $type = if ($effectiveDefinition.ContainsKey('url')) { 'remote' } else { 'local' }
        }
        $serverOut['type'] = $type

        if ($effectiveDefinition.ContainsKey('enabled')) {
            $serverOut['enabled'] = [bool]$effectiveDefinition['enabled']
        }

        if ($type -eq 'local') {
            $commandParts = @()
            if ($effectiveDefinition.ContainsKey('command')) {
                if (($effectiveDefinition['command'] -is [System.Collections.IEnumerable]) -and -not ($effectiveDefinition['command'] -is [string])) {
                    $commandParts += @($effectiveDefinition['command'])
                } else {
                    $commandParts += @([string]$effectiveDefinition['command'])
                }
            }
            if ($effectiveDefinition.ContainsKey('args')) {
                $commandParts += @($effectiveDefinition['args'])
            }
            $commandParts = @($commandParts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            if ($commandParts.Count -gt 0) {
                $serverOut['command'] = @($commandParts)
            }
            if ($effectiveDefinition.ContainsKey('env') -and ($effectiveDefinition['env'] -is [hashtable])) {
                $environment = @{}
                Set-BootstrapNonEmptyStringValues -Target $environment -Values $effectiveDefinition['env']
                if ($environment.Count -gt 0) {
                    $serverOut['environment'] = $environment
                }
            }
        } else {
            if ($effectiveDefinition.ContainsKey('url')) {
                $url = [string]$effectiveDefinition['url']
                if (-not [string]::IsNullOrWhiteSpace($url)) {
                    $serverOut['url'] = $url
                }
            }
            if ($effectiveDefinition.ContainsKey('headers') -and ($effectiveDefinition['headers'] -is [hashtable])) {
                $headers = @{}
                Set-BootstrapNonEmptyStringValues -Target $headers -Values $effectiveDefinition['headers']
                if ($headers.Count -gt 0) {
                    $serverOut['headers'] = $headers
                }
            }
        }

        if ($effectiveDefinition.ContainsKey('timeout')) {
            $serverOut['timeout'] = $effectiveDefinition['timeout']
        }
        if ($serverOut.Count -le 1 -and $serverOut.ContainsKey('type')) {
            return $null
        }
        return $serverOut
    }

    if ($Format -eq 'vscode' -or $Format -eq 'zcode') {
        $serverOut = @{}
        $type = ''
        if ($effectiveDefinition.ContainsKey('type')) {
            $type = [string]$effectiveDefinition['type']
        }
        if ([string]::IsNullOrWhiteSpace($type)) {
            $type = if ($effectiveDefinition.ContainsKey('url')) { 'http' } else { 'stdio' }
        }
        $serverOut['type'] = $type

        foreach ($propertyName in @('command', 'url')) {
            if ($effectiveDefinition.ContainsKey($propertyName)) {
                $value = [string]$effectiveDefinition[$propertyName]
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $serverOut[$propertyName] = $value
                }
            }
        }
        if ($effectiveDefinition.ContainsKey('args')) {
            $serverOut['args'] = @($effectiveDefinition['args'])
        }
        if ($effectiveDefinition.ContainsKey('headers') -and ($effectiveDefinition['headers'] -is [hashtable])) {
            $headers = @{}
            Set-BootstrapNonEmptyStringValues -Target $headers -Values $effectiveDefinition['headers']
            if ($headers.Count -gt 0) {
                $serverOut['headers'] = $headers
            }
        }
        if ($effectiveDefinition.ContainsKey('env') -and ($effectiveDefinition['env'] -is [hashtable])) {
            $envOut = @{}
            Set-BootstrapNonEmptyStringValues -Target $envOut -Values $effectiveDefinition['env']
            if ($envOut.Count -gt 0) {
                $serverOut['env'] = $envOut
            }
        }
        if ($serverOut.Count -le 1 -and $serverOut.ContainsKey('type')) {
            return $null
        }
        return $serverOut
    }

    if ($Format -eq 'zed') {
        $serverOut = @{}
        if ($effectiveDefinition.ContainsKey('url')) {
            $url = [string]$effectiveDefinition['url']
            if (-not [string]::IsNullOrWhiteSpace($url)) {
                $serverOut['url'] = $url
            }
        }
        if ($effectiveDefinition.ContainsKey('headers') -and ($effectiveDefinition['headers'] -is [hashtable])) {
            $headers = @{}
            Set-BootstrapNonEmptyStringValues -Target $headers -Values $effectiveDefinition['headers']
            if ($headers.Count -gt 0) {
                $serverOut['headers'] = $headers
            }
        }
        if ($serverOut.Count -eq 0) {
            if ($effectiveDefinition.ContainsKey('command')) {
                $commandPath = [string]$effectiveDefinition['command']
                if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
                    $serverOut['command'] = $commandPath
                }
            }
            if ($effectiveDefinition.ContainsKey('args')) {
                $serverOut['args'] = @($effectiveDefinition['args'])
            }
            if ($effectiveDefinition.ContainsKey('env') -and ($effectiveDefinition['env'] -is [hashtable])) {
                $envOut = @{}
                Set-BootstrapNonEmptyStringValues -Target $envOut -Values $effectiveDefinition['env']
                if ($envOut.Count -gt 0) {
                    $serverOut['env'] = $envOut
                }
            }
        }
        if ($serverOut.Count -eq 0) {
            return $null
        }
        return $serverOut
    }

    $result = @{}
    foreach ($propertyName in @('command', 'url', 'transport', 'type', 'serverUrl')) {
        if ($ServerDefinition.ContainsKey($propertyName)) {
            $value = [string]$ServerDefinition[$propertyName]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $result[$propertyName] = $value
            }
        }
    }
    if ($ServerDefinition.ContainsKey('args')) {
        $result['args'] = @($ServerDefinition['args'])
    }
    if ($ServerDefinition.ContainsKey('headers') -and ($ServerDefinition['headers'] -is [hashtable])) {
        $headers = @{}
        Set-BootstrapNonEmptyStringValues -Target $headers -Values $ServerDefinition['headers']
        if ($headers.Count -gt 0) {
            $result['headers'] = $headers
        }
    }
    if ($ServerDefinition.ContainsKey('env') -and ($ServerDefinition['env'] -is [hashtable])) {
        $envOut = @{}
        Set-BootstrapNonEmptyStringValues -Target $envOut -Values $ServerDefinition['env']
        if ($envOut.Count -gt 0) {
            $result['env'] = $envOut
        }
    }
    if ($ServerDefinition.ContainsKey('alwaysAllow')) {
        $result['alwaysAllow'] = @($ServerDefinition['alwaysAllow'])
    }
    if ($ServerDefinition.ContainsKey('disabled')) {
        $result['disabled'] = [bool]$ServerDefinition['disabled']
    }
    if ($ServerDefinition.ContainsKey('enabled')) {
        $result['enabled'] = [bool]$ServerDefinition['enabled']
    }
    if ($result.Count -eq 0) {
        return $null
    }
    return $result
}

function Merge-BootstrapMcpServers {
    param(
        [Parameter(Mandatory = $true)][hashtable]$TargetMap,
        [Parameter(Mandatory = $true)][hashtable]$SourceMap,
        [Parameter(Mandatory = $true)][ValidateSet('standard', 'opencode', 'vscode', 'zed', 'zcode')][string]$Format
    )

    $applied = 0
    foreach ($serverName in $SourceMap.Keys) {
        $serverDef = ConvertTo-BootstrapHashtable -InputObject $SourceMap[$serverName]
        if (-not ($serverDef -is [hashtable])) { continue }

        $serverOut = ConvertTo-BootstrapMcpServerEntry -ServerDefinition $serverDef -Format $Format
        if (-not ($serverOut -is [hashtable])) { continue }

        $currentServer = @{}
        if ($TargetMap.ContainsKey($serverName) -and ($TargetMap[$serverName] -is [hashtable])) {
            $currentServer = ConvertTo-BootstrapHashtable -InputObject $TargetMap[$serverName]
        }
        foreach ($propertyName in $serverOut.Keys) {
            $currentServer[$propertyName] = $serverOut[$propertyName]
        }
        $TargetMap[[string]$serverName] = $currentServer
        $applied += 1
    }
    return $applied
}

function Ensure-BootstrapJsonTargetFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Target,
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateSet('standard', 'opencode', 'vscode', 'zed', 'zcode')][string]$McpFormat = 'standard',
        [string]$McpPropertyName = 'mcpServers'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $settings = @{}
    if (Test-Path $Path) {
        try {
            $settings = Read-BootstrapJsonFile -Path $Path
            if (-not ($settings -is [hashtable])) { $settings = @{} }
        } catch {
            Write-Log "$Label invalido em $Path. O bootstrap vai preservar o arquivo existente e recriar o JSON mesclado." 'WARN'
            $settings = @{}
        }
    }

    $before = ((ConvertTo-BootstrapObjectGraph -InputObject $settings) | ConvertTo-Json -Depth 20 -Compress)

    if ($Target.ContainsKey('env') -and ($Target['env'] -is [hashtable])) {
        $envMap = Ensure-BootstrapNamedMap -Parent $settings -Name 'env'
        Set-BootstrapNonEmptyStringValues -Target $envMap -Values $Target['env']
    }

    if ($Target.ContainsKey('mcpServers') -and ($Target['mcpServers'] -is [hashtable])) {
        $mcpChanges = @{}
        $appliedMcpServers = Merge-BootstrapMcpServers -TargetMap $mcpChanges -SourceMap $Target['mcpServers'] -Format $McpFormat
        if ($appliedMcpServers -gt 0) {
            $mcpMap = Ensure-BootstrapNamedMap -Parent $settings -Name $McpPropertyName
            foreach ($serverName in $mcpChanges.Keys) {
                $mcpMap[[string]$serverName] = $mcpChanges[$serverName]
            }
        }
    }

    $after = ((ConvertTo-BootstrapObjectGraph -InputObject $settings) | ConvertTo-Json -Depth 20 -Compress)
    if ($before -eq $after) {
        return $false
    }

    Write-BootstrapJsonFile -Path $Path -Value $settings
    Write-Log ("Segredos aplicados em {0}: {1}" -f $Label, $Path)
    return $true
}

function Ensure-BootstrapZCodeStateMap {
    param([hashtable]$Store)

    $storageText = ''
    if ($Store.ContainsKey('mcp-storage')) {
        $storageText = [string]$Store['mcp-storage']
    }

    $storage = @{}
    if (-not [string]::IsNullOrWhiteSpace($storageText)) {
        try {
            $storage = ConvertTo-BootstrapHashtable -InputObject ($storageText | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            Write-Log 'ZCode mcp-storage invalido. O bootstrap vai recriar a estrutura MCP mesclada.' 'WARN'
            $storage = @{}
        }
    }

    $state = Ensure-BootstrapNamedMap -Parent $storage -Name 'state'
    $config = Ensure-BootstrapNamedMap -Parent $state -Name 'config'
    $mcp = Ensure-BootstrapNamedMap -Parent $config -Name 'mcp'
    $null = Ensure-BootstrapNamedMap -Parent $mcp -Name 'mcpServers'

    if (-not $state.ContainsKey('servers') -or -not ($state['servers'] -is [System.Collections.IEnumerable])) {
        $state['servers'] = @()
    } else {
        $state['servers'] = @($state['servers'])
    }

    return $storage
}

function Ensure-BootstrapZCodeSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('zCode') -or -not ($ResolvedTargets['zCode'] -is [hashtable])) {
        return $false
    }

    $target = ConvertTo-BootstrapHashtable -InputObject $ResolvedTargets['zCode']
    $storePath = Get-BootstrapZCodeStorePath
    if ([string]::IsNullOrWhiteSpace($storePath)) { return $false }

    $store = @{}
    if (Test-Path $storePath) {
        try {
            $store = Read-BootstrapJsonFile -Path $storePath
            if (-not ($store -is [hashtable])) { $store = @{} }
        } catch {
            Write-Log "ZCode store invalido em $storePath. O bootstrap vai preservar o arquivo existente e recriar o JSON mesclado." 'WARN'
            $store = @{}
        }
    }

    $before = ((ConvertTo-BootstrapObjectGraph -InputObject $store) | ConvertTo-Json -Depth 30 -Compress)
    $storage = Ensure-BootstrapZCodeStateMap -Store $store
    $state = Ensure-BootstrapNamedMap -Parent $storage -Name 'state'
    $config = Ensure-BootstrapNamedMap -Parent $state -Name 'config'
    $mcp = Ensure-BootstrapNamedMap -Parent $config -Name 'mcp'
    $mcpServers = Ensure-BootstrapNamedMap -Parent $mcp -Name 'mcpServers'

    if ($target.ContainsKey('mcpServers') -and ($target['mcpServers'] -is [hashtable])) {
        $mcpChanges = @{}
        $appliedMcpServers = Merge-BootstrapMcpServers -TargetMap $mcpChanges -SourceMap $target['mcpServers'] -Format 'zcode'
        if ($appliedMcpServers -gt 0) {
            foreach ($serverName in $mcpChanges.Keys) {
                $mcpServers[[string]$serverName] = $mcpChanges[$serverName]
            }

            $currentServers = @()
            if ($state.ContainsKey('servers')) {
                $currentServers = @($state['servers'])
            }
            $serversByName = @{}
            foreach ($serverItem in $currentServers) {
                $serverHash = ConvertTo-BootstrapHashtable -InputObject $serverItem
                if ($serverHash.Count -eq 0) { continue }
                $existingName = ''
                if ($serverHash.ContainsKey('name')) {
                    $existingName = [string]$serverHash['name']
                }
                if ([string]::IsNullOrWhiteSpace($existingName)) { continue }
                $serversByName[$existingName] = $serverHash
            }
            foreach ($serverName in $mcpChanges.Keys) {
                $sourceDefinition = ConvertTo-BootstrapHashtable -InputObject $target['mcpServers'][$serverName]
                $serverRecord = @{}
                if ($serversByName.ContainsKey($serverName)) {
                    $serverRecord = $serversByName[$serverName]
                }
                $serverRecord['id'] = "mcp-$serverName"
                $serverRecord['name'] = [string]$serverName
                $serverRecord['config'] = $mcpChanges[$serverName]
                if ($sourceDefinition.ContainsKey('enabled')) {
                    $serverRecord['enabled'] = [bool]$sourceDefinition['enabled']
                } elseif ($sourceDefinition.ContainsKey('disabled')) {
                    $serverRecord['enabled'] = (-not [bool]$sourceDefinition['disabled'])
                } elseif (-not $serverRecord.ContainsKey('enabled')) {
                    $serverRecord['enabled'] = $true
                }
                if (-not $serverRecord.ContainsKey('source')) {
                    $serverRecord['source'] = 'user'
                }
                if (-not $serverRecord.ContainsKey('status')) {
                    $serverRecord['status'] = 'disconnected'
                }
                $serverRecord['changed'] = $true
                $serversByName[$serverName] = $serverRecord
            }
            $state['servers'] = @($serversByName.Keys | Sort-Object | ForEach-Object { $serversByName[$_] })
        }
    }

    $store['mcp-storage'] = [string]((ConvertTo-BootstrapObjectGraph -InputObject $storage) | ConvertTo-Json -Depth 30 -Compress)
    $after = ((ConvertTo-BootstrapObjectGraph -InputObject $store) | ConvertTo-Json -Depth 30 -Compress)
    if ($before -eq $after) {
        return $false
    }

    Write-BootstrapJsonFile -Path $storePath -Value $store
    Write-Log ("Segredos aplicados em ZCode: {0}" -f $storePath)
    return $true
}

function Ensure-BootstrapVsCodeSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('vsCode') -or -not ($ResolvedTargets['vsCode'] -is [hashtable])) {
        return $false
    }

    return (Ensure-BootstrapJsonTargetFile -Path (Get-BootstrapVsCodeMcpConfigPath) -Target $ResolvedTargets['vsCode'] -Label 'VS Code MCP' -McpFormat 'vscode' -McpPropertyName 'servers')
}

function Ensure-BootstrapRooSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('roo') -or -not ($ResolvedTargets['roo'] -is [hashtable])) {
        return $false
    }

    return (Ensure-BootstrapJsonTargetFile -Path (Get-BootstrapRooMcpConfigPath) -Target $ResolvedTargets['roo'] -Label 'Roo MCP')
}

function Ensure-BootstrapClineSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('cline') -or -not ($ResolvedTargets['cline'] -is [hashtable])) {
        return $false
    }

    return (Ensure-BootstrapJsonTargetFile -Path (Get-BootstrapClineMcpConfigPath) -Target $ResolvedTargets['cline'] -Label 'Cline MCP')
}

function Ensure-BootstrapZedSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('zed') -or -not ($ResolvedTargets['zed'] -is [hashtable])) {
        return $false
    }

    return (Ensure-BootstrapJsonTargetFile -Path (Get-BootstrapZedConfigPath) -Target $ResolvedTargets['zed'] -Label 'Zed settings' -McpFormat 'zed' -McpPropertyName 'context_servers')
}

function Ensure-BootstrapOpenClawSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('openClaw') -or -not ($ResolvedTargets['openClaw'] -is [hashtable])) {
        return $false
    }

    return (Ensure-BootstrapJsonTargetFile -Path (Get-BootstrapOpenClawConfigPath) -Target $ResolvedTargets['openClaw'] -Label 'OpenClaw config')
}

function Ensure-BootstrapCometSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('comet') -or -not ($ResolvedTargets['comet'] -is [hashtable])) {
        return $false
    }

    return $false
}

function Ensure-BootstrapClaudeCodeSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('claudeCode') -or -not ($ResolvedTargets['claudeCode'] -is [hashtable])) {
        return $false
    }

    $userHome = Get-BootstrapUserHomePath
    if ([string]::IsNullOrWhiteSpace($userHome)) { return $false }

    $settingsPath = Join-Path (Join-Path $userHome '.claude') 'settings.json'
    $settings = @{}
    if (Test-Path $settingsPath) {
        try {
            $settings = Read-BootstrapJsonFile -Path $settingsPath
            if (-not ($settings -is [hashtable])) { $settings = @{} }
        } catch {
            Write-Log "Claude Code settings invalidos em $settingsPath. O bootstrap vai preservar o arquivo existente e recriar o JSON mesclado." 'WARN'
            $settings = @{}
        }
    }

    $before = ((ConvertTo-BootstrapObjectGraph -InputObject $settings) | ConvertTo-Json -Depth 20 -Compress)
    $target = $ResolvedTargets['claudeCode']

    if ($target.ContainsKey('env') -and ($target['env'] -is [hashtable])) {
        $envMap = Ensure-BootstrapNamedMap -Parent $settings -Name 'env'
        Set-BootstrapNonEmptyStringValues -Target $envMap -Values $target['env']
    }

    if ($target.ContainsKey('mcpServers') -and ($target['mcpServers'] -is [hashtable])) {
        $mcpChanges = @{}
        $appliedMcpServers = Merge-BootstrapMcpServers -TargetMap $mcpChanges -SourceMap $target['mcpServers'] -Format 'standard'
        if ($appliedMcpServers -gt 0) {
            $mcpMap = Ensure-BootstrapNamedMap -Parent $settings -Name 'mcpServers'
            foreach ($serverName in $mcpChanges.Keys) {
                $mcpMap[[string]$serverName] = $mcpChanges[$serverName]
            }
        }
    }

    $after = ((ConvertTo-BootstrapObjectGraph -InputObject $settings) | ConvertTo-Json -Depth 20 -Compress)
    if ($before -eq $after) {
        return $false
    }

    Write-BootstrapJsonFile -Path $settingsPath -Value $settings
    Write-Log "Segredos aplicados em Claude Code: $settingsPath"
    return $true
}

function Ensure-BootstrapClaudeDesktopSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('claudeDesktop') -or -not ($ResolvedTargets['claudeDesktop'] -is [hashtable])) {
        return $false
    }

    $settingsPath = Get-BootstrapClaudeDesktopConfigPath
    $settings = @{}
    if (Test-Path $settingsPath) {
        try {
            $settings = Read-BootstrapJsonFile -Path $settingsPath
            if (-not ($settings -is [hashtable])) { $settings = @{} }
        } catch {
            Write-Log "Claude Desktop config invalido em $settingsPath. O bootstrap vai preservar o arquivo existente e recriar o JSON mesclado." 'WARN'
            $settings = @{}
        }
    }

    $before = ((ConvertTo-BootstrapObjectGraph -InputObject $settings) | ConvertTo-Json -Depth 20 -Compress)
    $target = $ResolvedTargets['claudeDesktop']

    if ($target.ContainsKey('mcpServers') -and ($target['mcpServers'] -is [hashtable])) {
        $mcpChanges = @{}
        $appliedMcpServers = Merge-BootstrapMcpServers -TargetMap $mcpChanges -SourceMap $target['mcpServers'] -Format 'standard'
        if ($appliedMcpServers -gt 0) {
            $mcpMap = Ensure-BootstrapNamedMap -Parent $settings -Name 'mcpServers'
            foreach ($serverName in $mcpChanges.Keys) {
                $mcpMap[[string]$serverName] = $mcpChanges[$serverName]
            }
        }
    }

    $after = ((ConvertTo-BootstrapObjectGraph -InputObject $settings) | ConvertTo-Json -Depth 20 -Compress)
    if ($before -eq $after) {
        return $false
    }

    Write-BootstrapJsonFile -Path $settingsPath -Value $settings
    Write-Log "Segredos aplicados em Claude Desktop: $settingsPath"
    return $true
}

function Ensure-BootstrapCursorSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('cursor') -or -not ($ResolvedTargets['cursor'] -is [hashtable])) {
        return $false
    }

    return (Ensure-BootstrapJsonTargetFile -Path (Get-BootstrapCursorMcpConfigPath) -Target $ResolvedTargets['cursor'] -Label 'Cursor MCP' -McpFormat 'standard' -McpPropertyName 'mcpServers')
}

function Ensure-BootstrapWindsurfSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('windsurf') -or -not ($ResolvedTargets['windsurf'] -is [hashtable])) {
        return $false
    }

    $path = Get-BootstrapWindsurfMcpConfigPath
    $mcpPropertyName = if ([System.StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetFileName($path), 'settings.json')) { 'mcpServers' } else { 'mcpServers' }
    return (Ensure-BootstrapJsonTargetFile -Path $path -Target $ResolvedTargets['windsurf'] -Label 'Windsurf MCP' -McpFormat 'standard' -McpPropertyName $mcpPropertyName)
}

function Ensure-BootstrapTraeSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('trae') -or -not ($ResolvedTargets['trae'] -is [hashtable])) {
        return $false
    }

    return (Ensure-BootstrapJsonTargetFile -Path (Get-BootstrapTraeMcpConfigPath) -Target $ResolvedTargets['trae'] -Label 'Trae MCP' -McpFormat 'standard' -McpPropertyName 'mcpServers')
}

function Ensure-BootstrapOpenCodeSecrets {
    param([hashtable]$ResolvedTargets)

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('openCode') -or -not ($ResolvedTargets['openCode'] -is [hashtable])) {
        return $false
    }

    return (Ensure-BootstrapJsonTargetFile -Path (Get-BootstrapOpenCodeConfigPath) -Target $ResolvedTargets['openCode'] -Label 'OpenCode' -McpFormat 'opencode' -McpPropertyName 'mcp')
}

function Get-BootstrapVsCodeExtensionStatePath {
    return (Join-Path (Get-BootstrapDataRoot) 'vscode-extension-state.json')
}

function Get-BootstrapContinueConfigPath {
    $userHome = Get-BootstrapUserHomePath
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        return $null
    }

    return (Join-Path (Join-Path $userHome '.continue') 'config.yaml')
}

function Get-BootstrapContinueEnvPath {
    $userHome = Get-BootstrapUserHomePath
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        return $null
    }

    return (Join-Path (Join-Path $userHome '.continue') '.env')
}

function Get-BootstrapMcpStatePath {
    return (Join-Path (Get-BootstrapDataRoot) 'bootstrap-mcp-state.json')
}

function Get-BootstrapManagedMcpCapableTargets {
    return @('claudeCode', 'claudeDesktop', 'cursor', 'windsurf', 'trae', 'openCode', 'vsCode', 'roo', 'cline', 'continue', 'zed', 'zCode', 'openClaw')
}

function Get-BootstrapManagedMcpCatalog {
    return [ordered]@{
        github = [ordered]@{
            id = 'github'
            displayName = 'GitHub MCP Server'
            installKind = 'npm'
            package = '@modelcontextprotocol/server-github'
            authMode = 'token'
        }
        markitdown = [ordered]@{
            id = 'markitdown'
            displayName = 'Markitdown'
            installKind = 'uvtool'
            package = 'markitdown-mcp'
            commandName = 'markitdown-mcp'
            versionArgs = @('--help')
            authMode = 'none'
        }
        netdata = [ordered]@{
            id = 'netdata'
            displayName = 'Netdata'
            installKind = 'npm'
            package = 'mcp-remote'
            authMode = 'token-http'
        }
        context7 = [ordered]@{
            id = 'context7'
            displayName = 'Context7'
            installKind = 'npm'
            package = '@upstash/context7-mcp'
            authMode = 'optional-key'
        }
        'chrome-devtools' = [ordered]@{
            id = 'chrome-devtools'
            displayName = 'Chrome DevTools MCP'
            installKind = 'npm'
            package = 'chrome-devtools-mcp'
            authMode = 'none'
        }
        playwright = [ordered]@{
            id = 'playwright'
            displayName = 'Playwright'
            installKind = 'npm'
            package = '@playwright/mcp'
            authMode = 'none'
        }
        serena = [ordered]@{
            id = 'serena'
            displayName = 'Serena'
            installKind = 'uvtool'
            package = 'serena-agent@latest'
            commandName = 'serena'
            versionArgs = @('--version')
            installArgs = @('-p', '3.13', '--prerelease=allow')
            authMode = 'none'
        }
        firecrawl = [ordered]@{
            id = 'firecrawl'
            displayName = 'Firecrawl'
            installKind = 'npm'
            package = 'firecrawl-mcp'
            authMode = 'apiKey'
        }
        'desktop-commander' = [ordered]@{
            id = 'desktop-commander'
            displayName = 'Desktop Commander'
            installKind = 'npm'
            package = '@wonderwhy-er/desktop-commander'
            authMode = 'none'
        }
        notion = [ordered]@{
            id = 'notion'
            displayName = 'Notion'
            installKind = 'npm'
            package = 'mcp-remote'
            authMode = 'oauth'
        }
        supabase = [ordered]@{
            id = 'supabase'
            displayName = 'Supabase'
            installKind = 'npm'
            package = 'mcp-remote'
            authMode = 'oauth'
        }
        figma = [ordered]@{
            id = 'figma'
            displayName = 'Figma MCP Server'
            installKind = 'npm'
            package = 'mcp-remote'
            authMode = 'oauth'
        }
        apify = [ordered]@{
            id = 'apify'
            displayName = 'Apify'
            installKind = 'npm'
            package = '@apify/actors-mcp-server'
            authMode = 'oauth-or-token'
        }
        vercel = [ordered]@{
            id = 'vercel'
            displayName = 'Vercel MCP'
            installKind = 'npm'
            package = 'mcp-remote'
            authMode = 'oauth'
        }
        box = [ordered]@{
            id = 'box'
            displayName = 'Box MCP Server (Remote)'
            installKind = 'npm'
            package = 'mcp-remote'
            authMode = 'oauth-admin'
        }
    }
}

function Get-BootstrapManagedMcpProviders {
    param([Parameter(Mandatory = $true)]$SecretsData)

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData
    $catalog = Get-BootstrapSecretsProviderCatalog
    $managedProviders = ConvertTo-BootstrapHashtable -InputObject (Get-BootstrapActiveProviders -SecretsData $normalized -RequirePassedValidation)
    if (-not ($managedProviders -is [hashtable])) {
        $managedProviders = [ordered]@{}
    }

    foreach ($providerName in @('context7', 'firecrawl', 'apify', 'netdata', 'supabase')) {
        if ($managedProviders.Contains($providerName)) {
            continue
        }
        if (-not ($normalized.Contains('providers') -and ($normalized['providers'] -is [System.Collections.IDictionary]) -and $normalized['providers'].Contains($providerName))) {
            continue
        }

        $provider = ConvertTo-BootstrapHashtable -InputObject $normalized['providers'][$providerName]
        if (-not ($provider -is [hashtable])) {
            continue
        }

        $providerMeta = if ($catalog.Contains($providerName)) { ConvertTo-BootstrapHashtable -InputObject $catalog[$providerName] } else { @{} }
        $active = [ordered]@{}
        $providerDefaults = $null
        if ($provider.ContainsKey('defaults') -and ($provider['defaults'] -is [System.Collections.IDictionary])) {
            $providerDefaults = ConvertTo-BootstrapHashtable -InputObject $provider['defaults']
        }
        if ($providerDefaults -is [hashtable]) {
            foreach ($key in $providerDefaults.Keys) {
                $value = [string]$providerDefaults[$key]
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $active[$key] = $value
                }
            }
        } else {
            $providerMetaDefaults = $null
            if ($providerMeta.ContainsKey('defaults') -and ($providerMeta['defaults'] -is [System.Collections.IDictionary])) {
                $providerMetaDefaults = ConvertTo-BootstrapHashtable -InputObject $providerMeta['defaults']
            }
            if ($providerMetaDefaults -is [hashtable]) {
                foreach ($key in $providerMetaDefaults.Keys) {
                    $value = [string]$providerMetaDefaults[$key]
                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        $active[$key] = $value
                    }
                }
            }
        }

        $activeCredential = [string]$provider['activeCredential']
        $providerCredentials = $null
        if ($provider.ContainsKey('credentials') -and ($provider['credentials'] -is [System.Collections.IDictionary])) {
            $providerCredentials = ConvertTo-BootstrapHashtable -InputObject $provider['credentials']
        }
        if (-not [string]::IsNullOrWhiteSpace($activeCredential) -and ($providerCredentials -is [hashtable]) -and $providerCredentials.Contains($activeCredential)) {
            $credential = ConvertTo-BootstrapHashtable -InputObject $providerCredentials[$activeCredential]
            if ($credential -is [hashtable]) {
                $active['credentialId'] = $activeCredential
                $active['displayName'] = [string]$credential['displayName']
                foreach ($key in $credential.Keys) {
                    if ($key -in @('displayName', 'secret', 'secretKind', 'validation')) { continue }
                    $value = [string]$credential[$key]
                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        $active[$key] = $value
                    }
                }

                $secret = [string]$credential['secret']
                if (-not [string]::IsNullOrWhiteSpace($secret)) {
                    $secretKind = if (-not [string]::IsNullOrWhiteSpace([string]$credential['secretKind'])) {
                        [string]$credential['secretKind']
                    } elseif ($providerMeta.ContainsKey('secretKind')) {
                        [string]$providerMeta['secretKind']
                    } else {
                        'secret'
                    }
                    switch ($secretKind) {
                        'apiKey' { $active['apiKey'] = $secret }
                        'token' { $active['token'] = $secret }
                        default { $active['secret'] = $secret }
                    }
                    $active['validationBypassed'] = $true
                }
            }
        }

        if ($active.Count -gt 0) {
            $managedProviders[$providerName] = $active
        }
    }

    return $managedProviders
}

function New-BootstrapManagedMcpCommandServer {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Args = @(),
        [hashtable]$Env = @{},
        [bool]$Disabled = $false,
        [bool]$Enabled = $true,
        [string[]]$AlwaysAllow = @()
    )

    $server = [ordered]@{
        command = $Command
    }
    if (@($Args).Count -gt 0) {
        $server['args'] = @($Args)
    }
    if ($Env -and ($Env -is [hashtable]) -and $Env.Count -gt 0) {
        $server['env'] = $Env
    }
    if (@($AlwaysAllow).Count -gt 0) {
        $server['alwaysAllow'] = @($AlwaysAllow)
    }
    if ($Disabled) {
        $server['disabled'] = $true
    } else {
        $server['enabled'] = $Enabled
    }

    return $server
}

function New-BootstrapManagedMcpRemoteBridgeServer {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Headers = @{},
        [switch]$AllowHttp
    )

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add('-y')
    $args.Add('mcp-remote@latest')

    if ($AllowHttp -or $Url.StartsWith('http://')) {
        $args.Add('--http')
        $args.Add($Url)
        if ($Url.StartsWith('http://')) {
            $args.Add('--allow-http')
        }
    } else {
        $args.Add($Url)
    }

    foreach ($headerName in ($Headers.Keys | Sort-Object)) {
        $args.Add('--header')
        $args.Add(('{0}: {1}' -f $headerName, [string]$Headers[$headerName]))
    }

    return (New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @($args.ToArray()))
}

function Get-BootstrapManagedSupabaseMcpUrl {
    param([hashtable]$ManagedProviders)

    $baseUrl = 'https://mcp.supabase.com/mcp'
    $projectRef = ''
    $readOnly = 'true'

    $provider = $null
    if ($ManagedProviders.Contains('supabase') -and ($ManagedProviders['supabase'] -is [System.Collections.IDictionary])) {
        $provider = ConvertTo-BootstrapHashtable -InputObject $ManagedProviders['supabase']
    }

    if ($provider -is [hashtable]) {
        if (-not [string]::IsNullOrWhiteSpace([string]$provider['baseUrl'])) {
            $baseUrl = [string]$provider['baseUrl']
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$provider['projectRef'])) {
            $projectRef = [string]$provider['projectRef']
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$provider['readOnly'])) {
            $readOnly = [string]$provider['readOnly']
        }
    }

    $queryParts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::Equals($readOnly, 'false', [System.StringComparison]::OrdinalIgnoreCase)) {
        $queryParts.Add('read_only=true')
    }
    if (-not [string]::IsNullOrWhiteSpace($projectRef)) {
        $queryParts.Add(('project_ref={0}' -f [uri]::EscapeDataString($projectRef)))
    }

    if ($queryParts.Count -eq 0) {
        return $baseUrl
    }

    $separator = if ($baseUrl.Contains('?')) { '&' } else { '?' }
    return ($baseUrl + $separator + [string]::Join('&', @($queryParts.ToArray())))
}

function Get-BootstrapManagedMcpServers {
    param([Parameter(Mandatory = $true)][hashtable]$ManagedProviders)

    $servers = [ordered]@{}

    $githubProvider = $null
    if ($ManagedProviders.Contains('github') -and ($ManagedProviders['github'] -is [System.Collections.IDictionary])) {
        $githubProvider = ConvertTo-BootstrapHashtable -InputObject $ManagedProviders['github']
    }
    if ($githubProvider -is [hashtable] -and -not [string]::IsNullOrWhiteSpace([string]$githubProvider['token'])) {
        $servers['github'] = New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @('-y', '@modelcontextprotocol/server-github') -Env ([ordered]@{
            GITHUB_TOKEN = [string]$githubProvider['token']
        })
    }

    $servers['markitdown'] = New-BootstrapManagedMcpCommandServer -Command 'markitdown-mcp'
    $servers['chrome-devtools'] = New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @('-y', 'chrome-devtools-mcp@latest', '--isolated')
    $servers['playwright'] = New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @('-y', '@playwright/mcp@latest', '--isolated')
    $servers['serena'] = New-BootstrapManagedMcpCommandServer -Command 'serena' -Args @('start-mcp-server', '--project-from-cwd')
    $servers['desktop-commander'] = New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @('-y', '@wonderwhy-er/desktop-commander@latest', '--no-onboarding')

    $context7Provider = $null
    if ($ManagedProviders.Contains('context7') -and ($ManagedProviders['context7'] -is [System.Collections.IDictionary])) {
        $context7Provider = ConvertTo-BootstrapHashtable -InputObject $ManagedProviders['context7']
    }
    if ($context7Provider -is [hashtable] -and -not [string]::IsNullOrWhiteSpace([string]$context7Provider['apiKey'])) {
        $servers['context7'] = New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @('-y', '@upstash/context7-mcp') -Env ([ordered]@{
            CONTEXT7_API_KEY = [string]$context7Provider['apiKey']
        })
    } else {
        $servers['context7'] = New-BootstrapManagedMcpRemoteBridgeServer -Url 'https://mcp.context7.com/mcp'
    }

    $firecrawlProvider = $null
    if ($ManagedProviders.Contains('firecrawl') -and ($ManagedProviders['firecrawl'] -is [System.Collections.IDictionary])) {
        $firecrawlProvider = ConvertTo-BootstrapHashtable -InputObject $ManagedProviders['firecrawl']
    }
    if ($firecrawlProvider -is [hashtable] -and -not [string]::IsNullOrWhiteSpace([string]$firecrawlProvider['apiKey'])) {
        $servers['firecrawl'] = New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @('-y', 'firecrawl-mcp') -Env ([ordered]@{
            FIRECRAWL_API_KEY = [string]$firecrawlProvider['apiKey']
        })
    }

    $apifyProvider = $null
    if ($ManagedProviders.Contains('apify') -and ($ManagedProviders['apify'] -is [System.Collections.IDictionary])) {
        $apifyProvider = ConvertTo-BootstrapHashtable -InputObject $ManagedProviders['apify']
    }
    if ($apifyProvider -is [hashtable] -and -not [string]::IsNullOrWhiteSpace([string]$apifyProvider['token'])) {
        $servers['apify'] = New-BootstrapManagedMcpCommandServer -Command 'npx' -Args @('-y', '@apify/actors-mcp-server') -Env ([ordered]@{
            APIFY_TOKEN = [string]$apifyProvider['token']
            TELEMETRY_ENABLED = 'false'
        })
    } else {
        $servers['apify'] = New-BootstrapManagedMcpRemoteBridgeServer -Url 'https://mcp.apify.com'
    }

    $netdataProvider = $null
    if ($ManagedProviders.Contains('netdata') -and ($ManagedProviders['netdata'] -is [System.Collections.IDictionary])) {
        $netdataProvider = ConvertTo-BootstrapHashtable -InputObject $ManagedProviders['netdata']
    }
    if ($netdataProvider -is [hashtable] -and -not [string]::IsNullOrWhiteSpace([string]$netdataProvider['token']) -and -not [string]::IsNullOrWhiteSpace([string]$netdataProvider['baseUrl'])) {
        $servers['netdata'] = New-BootstrapManagedMcpRemoteBridgeServer -Url ([string]$netdataProvider['baseUrl']) -Headers ([ordered]@{
            Authorization = ('Bearer {0}' -f [string]$netdataProvider['token'])
        }) -AllowHttp
    }

    $servers['notion'] = New-BootstrapManagedMcpRemoteBridgeServer -Url 'https://mcp.notion.com/mcp'
    $servers['supabase'] = New-BootstrapManagedMcpRemoteBridgeServer -Url (Get-BootstrapManagedSupabaseMcpUrl -ManagedProviders $ManagedProviders)
    $servers['figma'] = New-BootstrapManagedMcpRemoteBridgeServer -Url 'https://mcp.figma.com/mcp'
    $servers['vercel'] = New-BootstrapManagedMcpRemoteBridgeServer -Url 'https://mcp.vercel.com'
    $servers['box'] = New-BootstrapManagedMcpRemoteBridgeServer -Url 'https://mcp.box.com'

    return $servers
}

function Merge-BootstrapManagedMcpTargets {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ResolvedTargets,
        [Parameter(Mandatory = $true)][hashtable]$ManagedProviders
    )

    $managedServers = Get-BootstrapManagedMcpServers -ManagedProviders $ManagedProviders
    foreach ($targetName in @(Get-BootstrapManagedMcpCapableTargets)) {
        if (-not ($ResolvedTargets.Contains($targetName) -and ($ResolvedTargets[$targetName] -is [hashtable]))) {
            continue
        }

        $target = ConvertTo-BootstrapHashtable -InputObject $ResolvedTargets[$targetName]
        if (-not ($target.ContainsKey('mcpServers') -and ($target['mcpServers'] -is [hashtable]))) {
            $target['mcpServers'] = [ordered]@{}
        }

        foreach ($serverName in $managedServers.Keys) {
            if ($target['mcpServers'].Contains($serverName)) {
                continue
            }
            $target['mcpServers'][$serverName] = ConvertTo-BootstrapHashtable -InputObject $managedServers[$serverName]
        }

        $ResolvedTargets[$targetName] = $target
    }

    return $ResolvedTargets
}

function Ensure-BootstrapManagedMcps {
    param([hashtable]$State)

    Ensure-BootstrapNodeCore -State $State
    Ensure-BootstrapPythonCore -State $State

    $secretsPath = if (-not [string]::IsNullOrWhiteSpace([string]$State.SecretsPath) -and (Test-Path $State.SecretsPath)) {
        [string]$State.SecretsPath
    } else {
        Get-BootstrapSecretsPath
    }
    $secretsData = if (Test-Path $secretsPath) { Read-BootstrapJsonFile -Path $secretsPath } else { Get-BootstrapSecretsTemplate }
    $resolvedTargets = Get-BootstrapResolvedSecretsTargets -SecretsData $secretsData -IncludeManagedMcps
    $managedProviders = Get-BootstrapManagedMcpProviders -SecretsData $secretsData
    $managedServers = Get-BootstrapManagedMcpServers -ManagedProviders $managedProviders
    $catalog = Get-BootstrapManagedMcpCatalog
    $statePath = Get-BootstrapMcpStatePath

    $summary = [ordered]@{
        path = $statePath
        generatedAt = (Get-Date).ToString('o')
        packages = @()
        mcps = @()
        authPending = @()
        targets = [ordered]@{
            claudeCodeUpdated = $false
            claudeDesktopUpdated = $false
            cursorUpdated = $false
            windsurfUpdated = $false
            traeUpdated = $false
            openCodeUpdated = $false
            vsCodeUpdated = $false
            rooUpdated = $false
            clineUpdated = $false
            zedUpdated = $false
            zCodeUpdated = $false
            openClawUpdated = $false
        }
        continue = [ordered]@{}
    }

    $packageRecords = New-Object System.Collections.Generic.List[hashtable]
    $seenPackages = @{}
    foreach ($definition in $catalog.Values) {
        $kind = [string]$definition['installKind']
        $package = [string]$definition['package']
        if ([string]::IsNullOrWhiteSpace($kind) -or [string]::IsNullOrWhiteSpace($package)) {
            continue
        }
        $cacheKey = '{0}:{1}' -f $kind, $package
        if ($seenPackages.Contains($cacheKey)) {
            continue
        }
        $seenPackages[$cacheKey] = $true

        switch ($kind) {
            'npm' {
                Ensure-NpmGlobalPackage -NpmCmd $State.NodeInfo.NpmCmd -Package $package -DisplayName $package
                $packageRecords.Add([ordered]@{
                    kind = 'npm'
                    package = $package
                    installed = $true
                })
            }
            'uvtool' {
                $versionArgs = if ($definition.Contains('versionArgs')) { @($definition['versionArgs']) } else { @('--version') }
                $installArgs = if ($definition.Contains('installArgs')) { @($definition['installArgs']) } else { @() }
                Ensure-UvToolPackage -Package $package -CommandName ([string]$definition['commandName']) -DisplayName ([string]$definition['displayName']) -VersionArgs $versionArgs -InstallArgs $installArgs
                $packageRecords.Add([ordered]@{
                    kind = 'uvtool'
                    package = $package
                    installed = $true
                })
            }
        }
    }
    $summary.packages = @($packageRecords.ToArray())

    foreach ($mcpId in $catalog.Keys) {
        $definition = ConvertTo-BootstrapHashtable -InputObject $catalog[$mcpId]
        $configured = $managedServers.Contains($mcpId)
        $server = if ($configured) { ConvertTo-BootstrapHashtable -InputObject $managedServers[$mcpId] } else { @{} }
        $mode = 'none'
        if ($configured) {
            if ([string]$server['command'] -eq 'npx' -and @($server['args']) -contains 'mcp-remote@latest') {
                $mode = 'remote-bridge'
            } else {
                $mode = 'local'
            }
        }

        $authMode = [string]$definition['authMode']
        $authPending = $false
        $reason = ''
        switch ($authMode) {
            'oauth' {
                if ($configured) {
                    $authPending = $true
                    $reason = 'Autorizacao OAuth sera solicitada no primeiro uso.'
                }
            }
            'oauth-admin' {
                if ($configured) {
                    $authPending = $true
                    $reason = 'Pode exigir habilitacao do Box MCP e autorizacao/admin no tenant.'
                }
            }
            'oauth-or-token' {
                if ($configured -and $mode -eq 'remote-bridge') {
                    $authPending = $true
                    $reason = 'Sem token local ativo; o login OAuth sera solicitado no primeiro uso.'
                }
            }
            'apiKey' {
                if (-not $configured) {
                    $authPending = $true
                    $reason = 'Credencial ativa ausente para habilitar este MCP local.'
                }
            }
            'token-http' {
                if (-not $configured) {
                    $authPending = $true
                    $reason = 'Netdata exige URL MCP local e token ativo para ser habilitado.'
                }
            }
        }

        $record = [ordered]@{
            id = [string]$mcpId
            displayName = [string]$definition['displayName']
            configured = $configured
            mode = $mode
            authPending = $authPending
            reason = $reason
        }
        $summary.mcps += @($record)
        if ($authPending) {
            $summary.authPending += @([ordered]@{
                id = [string]$mcpId
                displayName = [string]$definition['displayName']
                reason = $reason
            })
        }
    }

    if ($resolvedTargets.ContainsKey('claudeCode') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['claudeCode'])) {
        $summary.targets.claudeCodeUpdated = Ensure-BootstrapClaudeCodeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('claudeDesktop') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['claudeDesktop'])) {
        $summary.targets.claudeDesktopUpdated = Ensure-BootstrapClaudeDesktopSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('cursor') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['cursor'])) {
        $summary.targets.cursorUpdated = Ensure-BootstrapCursorSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('windsurf') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['windsurf'])) {
        $summary.targets.windsurfUpdated = Ensure-BootstrapWindsurfSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('trae') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['trae'])) {
        $summary.targets.traeUpdated = Ensure-BootstrapTraeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('openCode') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['openCode'])) {
        $summary.targets.openCodeUpdated = Ensure-BootstrapOpenCodeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('vsCode') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['vsCode'])) {
        $summary.targets.vsCodeUpdated = Ensure-BootstrapVsCodeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('roo') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['roo'])) {
        $summary.targets.rooUpdated = Ensure-BootstrapRooSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('cline') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['cline'])) {
        $summary.targets.clineUpdated = Ensure-BootstrapClineSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('zed') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['zed'])) {
        $summary.targets.zedUpdated = Ensure-BootstrapZedSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('zCode') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['zCode'])) {
        $summary.targets.zCodeUpdated = Ensure-BootstrapZCodeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('openClaw') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['openClaw'])) {
        $summary.targets.openClawUpdated = Ensure-BootstrapOpenClawSecrets -ResolvedTargets $resolvedTargets
    }

    $summary.continue = Ensure-BootstrapContinueExtensionConfig -ResolvedTargets $resolvedTargets

    Write-BootstrapJsonFile -Path $statePath -Value $summary
    Write-Log ("Estado local dos MCPs gerenciados sincronizado: {0}" -f $statePath)

    $State.McpStatePath = $statePath
    $State.McpSummary = $summary
    return $summary
}

function Get-BootstrapVsCodeExtensionCatalog {
    return [ordered]@{
        'augment.vscode-augment' = [ordered]@{
            id = 'augment.vscode-augment'
            displayName = 'Augment'
            channels = @('stable', 'insiders')
            configKind = 'manual-auth'
            authPendingReason = 'Login via navegador exigido pela extensao.'
        }
        'kilocode.Kilo-Code' = [ordered]@{
            id = 'kilocode.Kilo-Code'
            displayName = 'Kilo Code'
            channels = @('stable', 'insiders')
            configKind = 'manual-auth'
            authPendingReason = 'Conta/configuracao inicial exigida pela extensao.'
        }
        'Kombai.kombai' = [ordered]@{
            id = 'Kombai.kombai'
            displayName = 'Kombai'
            channels = @('stable', 'insiders')
            configKind = 'manual-auth'
            authPendingReason = 'Login via navegador exigido pela extensao.'
        }
        'laurids.agent-skills-sh' = [ordered]@{
            id = 'laurids.agent-skills-sh'
            displayName = 'Agent Skills'
            channels = @('stable', 'insiders')
            configKind = 'none'
            authPendingReason = ''
        }
        'digitarald.agent-memory' = [ordered]@{
            id = 'digitarald.agent-memory'
            displayName = 'Agent Memory'
            channels = @('stable', 'insiders')
            preferPreRelease = $true
            configKind = 'vscode-settings'
            authPendingReason = ''
        }
        'RooVeterinaryInc.roo-code-nightly' = [ordered]@{
            id = 'RooVeterinaryInc.roo-code-nightly'
            displayName = 'Roo Code Nightly'
            channels = @('stable', 'insiders')
            configKind = 'mcp-only'
            authPendingReason = 'Selecao de provedor/modelo ainda depende da UI da extensao.'
        }
        'ms-toolsai.jupyter-renderers' = [ordered]@{
            id = 'ms-toolsai.jupyter-renderers'
            displayName = 'Jupyter Notebook Renderers'
            channels = @('stable', 'insiders')
            configKind = 'none'
            authPendingReason = ''
        }
        'saoudrizwan.cline-nightly' = [ordered]@{
            id = 'saoudrizwan.cline-nightly'
            displayName = 'Cline (Nightly)'
            channels = @('stable', 'insiders')
            preferPreRelease = $true
            configKind = 'mcp-only'
            authPendingReason = 'Autenticacao BYOK/Cline Provider depende do cofre interno da extensao.'
        }
        'Continue.continue' = [ordered]@{
            id = 'Continue.continue'
            displayName = 'Continue'
            channels = @('stable', 'insiders')
            configKind = 'continue'
            authPendingReason = ''
        }
    }
}

function Get-BootstrapVsCodeEditorTargets {
    $targets = [ordered]@{}
    $targets['stable'] = [ordered]@{
        name = 'stable'
        displayName = 'VS Code'
        cliPath = Resolve-BootstrapVsCodeCliPath -Channel 'stable'
        settingsPath = Get-BootstrapVsCodeSettingsPath
    }
    $targets['insiders'] = [ordered]@{
        name = 'insiders'
        displayName = 'VS Code Insiders'
        cliPath = Resolve-BootstrapVsCodeCliPath -Channel 'insiders'
        settingsPath = Get-BootstrapVsCodeInsidersSettingsPath
    }

    foreach ($channel in @($targets.Keys)) {
        $targets[$channel]['available'] = -not [string]::IsNullOrWhiteSpace([string]$targets[$channel]['cliPath'])
    }

    return $targets
}

function Invoke-BootstrapCommandCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Alias('Args')][string[]]$CommandArgs = @()
    )

    try {
        $output = & $Exe @CommandArgs 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = 0
        }
        return [ordered]@{
            ExitCode = [int]$exitCode
            Output = @($output)
        }
    } catch {
        return [ordered]@{
            ExitCode = 1
            Output = @([string]$_.Exception.Message)
        }
    }
}

function Get-BootstrapInstalledVsCodeExtensions {
    param([Parameter(Mandatory = $true)][string]$CliPath)

    if ([string]::IsNullOrWhiteSpace($CliPath) -or -not (Test-Path $CliPath)) {
        return @()
    }

    $result = Invoke-BootstrapCommandCapture -Exe $CliPath -Args @('--list-extensions')
    if ($result.ExitCode -ne 0) {
        Write-Log ("Falha ao listar extensoes de {0}: {1}" -f $CliPath, ((@($result.Output) -join ' ') -replace '\s+', ' ').Trim()) 'WARN'
        return @()
    }

    $extensions = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($result.Output)) {
        $trimmed = [string]$line
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $extensions.Add($trimmed.Trim())
    }

    return @($extensions.ToArray())
}

function Ensure-BootstrapVsCodeExtensionInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$CliPath,
        [Parameter(Mandatory = $true)]$ExtensionDefinition,
        [Parameter(Mandatory = $true)][string[]]$InstalledExtensions,
        [Parameter(Mandatory = $true)][string]$EditorLabel
    )

    $extensionId = [string]$ExtensionDefinition['id']
    if ($InstalledExtensions -contains $extensionId) {
        Write-Log ("Extensao ja instalada em {0}: {1}" -f $EditorLabel, $extensionId)
        return [ordered]@{
            installed = $true
            changed = $false
            error = ''
        }
    }

    $preferPreRelease = [bool]$ExtensionDefinition['preferPreRelease']
    $installArgs = @('--install-extension', $extensionId, '--force')
    if ($preferPreRelease) {
        $installArgs += @('--pre-release')
    }

    $result = Invoke-BootstrapCommandCapture -Exe $CliPath -Args $installArgs
    if ($result.ExitCode -ne 0) {
        $errorText = ((@($result.Output) -join ' ') -replace '\s+', ' ').Trim()
        $needsPreReleaseRetry = (
            -not $preferPreRelease -and
            ($errorText -match 'has no release version' -or $errorText -match 'pre-?release')
        )

        if ($needsPreReleaseRetry) {
            $preReleaseArgs = @('--install-extension', $extensionId, '--force', '--pre-release')
            $preReleaseResult = Invoke-BootstrapCommandCapture -Exe $CliPath -Args $preReleaseArgs
            if ($preReleaseResult.ExitCode -eq 0) {
                Write-Log ("Extensao pre-release instalada em {0}: {1}" -f $EditorLabel, $extensionId)
                return [ordered]@{
                    installed = $true
                    changed = $true
                    error = ''
                }
            }

            $errorText = ((@($preReleaseResult.Output) -join ' ') -replace '\s+', ' ').Trim()
        }

        return [ordered]@{
            installed = $false
            changed = $false
            error = $errorText
        }
    }

    if ($preferPreRelease) {
        Write-Log ("Extensao pre-release instalada em {0}: {1}" -f $EditorLabel, $extensionId)
    } else {
        Write-Log ("Extensao instalada em {0}: {1}" -f $EditorLabel, $extensionId)
    }
    return [ordered]@{
        installed = $true
        changed = $true
        error = ''
    }
}

function Ensure-BootstrapJsonPropertyFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $settings = @{}
    if (Test-Path $Path) {
        try {
            $settings = Read-BootstrapJsonFile -Path $Path
            if (-not ($settings -is [hashtable])) {
                $settings = @{}
            }
        } catch {
            $backupPath = Backup-BootstrapFile -Path $Path
            if ($backupPath) {
                Write-Log ("{0} invalido; backup criado: {1}" -f $Label, $backupPath) 'WARN'
            }
            $settings = @{}
        }
    }

    $before = ((ConvertTo-BootstrapObjectGraph -InputObject $settings) | ConvertTo-Json -Depth 20 -Compress)
    foreach ($name in $Values.Keys) {
        $settings[[string]$name] = $Values[$name]
    }
    $after = ((ConvertTo-BootstrapObjectGraph -InputObject $settings) | ConvertTo-Json -Depth 20 -Compress)

    if ($before -eq $after) {
        return $false
    }

    if (Test-Path $Path) {
        $backupPath = Backup-BootstrapFile -Path $Path
        if ($backupPath) {
            Write-Log ("Backup criado antes de atualizar {0}: {1}" -f $Label, $backupPath)
        }
    }

    Write-BootstrapJsonFile -Path $Path -Value $settings
    Write-Log ("Configuracao aplicada em {0}: {1}" -f $Label, $Path)
    return $true
}

function ConvertTo-BootstrapEnvFileLine {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return ('{0}="{1}"' -f $Name, $escaped)
}

function Write-BootstrapTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Ensure-BootstrapTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $current = if (Test-Path $Path) { [System.IO.File]::ReadAllText($Path) } else { '' }
    if ($current -eq $Content) {
        return $false
    }

    if (Test-Path $Path) {
        $backupPath = Backup-BootstrapFile -Path $Path
        if ($backupPath) {
            Write-Log ("Backup criado antes de atualizar {0}: {1}" -f $Label, $backupPath)
        }
    }

    Write-BootstrapTextFile -Path $Path -Content $Content
    Write-Log ("Arquivo atualizado em {0}: {1}" -f $Label, $Path)
    return $true
}

function Convert-BootstrapContinueScalarToYaml {
    param($Value)

    if ($Value -is [bool]) {
        return ($(if ($Value) { 'true' } else { 'false' }))
    }
    if ($null -eq $Value) {
        return '""'
    }

    $text = [string]$Value
    if ($text -match '^[A-Za-z0-9._/${}{:-]+$') {
        return $text
    }

    $escaped = $text.Replace('\', '\\').Replace('"', '\"')
    return ('"{0}"' -f $escaped)
}

function Convert-BootstrapMcpServerToContinueYamlLines {
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [Parameter(Mandatory = $true)][hashtable]$ServerDefinition
    )

    $server = ConvertTo-BootstrapHashtable -InputObject $ServerDefinition
    if (-not ($server -is [hashtable])) {
        return @()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('  - name: {0}' -f (Convert-BootstrapContinueScalarToYaml -Value $ServerName)))

    foreach ($propertyName in @('command', 'cwd', 'url')) {
        if ($server.ContainsKey($propertyName) -and -not [string]::IsNullOrWhiteSpace([string]$server[$propertyName])) {
            $lines.Add(('    {0}: {1}' -f $propertyName, (Convert-BootstrapContinueScalarToYaml -Value $server[$propertyName])))
        }
    }

    if ($server.ContainsKey('args') -and ($server['args'] -is [System.Collections.IEnumerable])) {
        $args = @($server['args'])
        if ($args.Count -gt 0) {
            $lines.Add('    args:')
            foreach ($arg in $args) {
                $lines.Add(('      - {0}' -f (Convert-BootstrapContinueScalarToYaml -Value $arg)))
            }
        }
    }

    if ($server.ContainsKey('env') -and ($server['env'] -is [hashtable])) {
        $envMap = @{}
        Set-BootstrapNonEmptyStringValues -Target $envMap -Values $server['env']
        if ($envMap.Count -gt 0) {
            $lines.Add('    env:')
            foreach ($name in ($envMap.Keys | Sort-Object)) {
                $secretRef = '${{ secrets.' + [string]$name + ' }}'
                $lines.Add(('      {0}: {1}' -f $name, (Convert-BootstrapContinueScalarToYaml -Value $secretRef)))
            }
        }
    }

    return @($lines.ToArray())
}

function Ensure-BootstrapContinueExtensionConfig {
    param([hashtable]$ResolvedTargets)

    $summary = [ordered]@{
        envPath = Get-BootstrapContinueEnvPath
        configPath = Get-BootstrapContinueConfigPath
        envUpdated = $false
        configUpdated = $false
        configured = $false
    }

    if (-not ($ResolvedTargets -is [hashtable]) -or -not $ResolvedTargets.ContainsKey('continue') -or -not ($ResolvedTargets['continue'] -is [hashtable])) {
        return $summary
    }

    $continueTarget = ConvertTo-BootstrapHashtable -InputObject $ResolvedTargets['continue']
    $envValues = @{}
    if ($continueTarget.ContainsKey('env') -and ($continueTarget['env'] -is [hashtable])) {
        Set-BootstrapNonEmptyStringValues -Target $envValues -Values $continueTarget['env']
    }

    $envLines = New-Object System.Collections.Generic.List[string]
    foreach ($name in ($envValues.Keys | Sort-Object)) {
        $envLines.Add((ConvertTo-BootstrapEnvFileLine -Name $name -Value ([string]$envValues[$name])))
    }

    $yamlLines = New-Object System.Collections.Generic.List[string]
    $yamlLines.Add('# Gerado automaticamente pelo bootstrap local.')
    $yamlLines.Add('# Modelos nao sao fixados automaticamente para evitar IDs de modelo frageis.')
    $yamlLines.Add('name: Bootstrap Local Config')
    $yamlLines.Add('version: 1.0.0')
    $yamlLines.Add('schema: v1')

    $mcpLines = New-Object System.Collections.Generic.List[string]
    if ($continueTarget.ContainsKey('mcpServers') -and ($continueTarget['mcpServers'] -is [hashtable])) {
        foreach ($serverName in ($continueTarget['mcpServers'].Keys | Sort-Object)) {
            $serverDefinition = ConvertTo-BootstrapHashtable -InputObject $continueTarget['mcpServers'][$serverName]
            if (-not ($serverDefinition -is [hashtable])) { continue }
            if ($serverDefinition.ContainsKey('enabled') -and (-not [bool]$serverDefinition['enabled'])) { continue }
            foreach ($line in @(Convert-BootstrapMcpServerToContinueYamlLines -ServerName ([string]$serverName) -ServerDefinition $serverDefinition)) {
                $mcpLines.Add($line)
            }
        }
    }

    if ($mcpLines.Count -gt 0) {
        $yamlLines.Add('mcpServers:')
        foreach ($line in $mcpLines) {
            $yamlLines.Add($line)
        }
    }

    $summary.configured = ($envValues.Count -gt 0) -or ($mcpLines.Count -gt 0)
    if (-not $summary.configured) {
        return $summary
    }

    $envContent = [string]::Join([Environment]::NewLine, @($envLines.ToArray()))
    if ($envLines.Count -gt 0) {
        if ($envContent.Length -gt 0) {
            $envContent += [Environment]::NewLine
        }
        $summary.envUpdated = Ensure-BootstrapTextFile -Path $summary.envPath -Content $envContent -Label 'Continue .env'
    } else {
        $summary.envUpdated = $false
    }

    $configContent = [string]::Join([Environment]::NewLine, @($yamlLines.ToArray())) + [Environment]::NewLine
    $summary.configUpdated = Ensure-BootstrapTextFile -Path $summary.configPath -Content $configContent -Label 'Continue config.yaml'

    return $summary
}

function Ensure-BootstrapVsCodeExtensions {
    param([hashtable]$State)

    $bundlePath = if (-not [string]::IsNullOrWhiteSpace([string]$State.SecretsPath) -and (Test-Path $State.SecretsPath)) {
        [string]$State.SecretsPath
    } else {
        Get-BootstrapSecretsPath
    }

    $secretsData = if (Test-Path $bundlePath) { Read-BootstrapJsonFile -Path $bundlePath } else { Get-BootstrapSecretsTemplate }
    $resolvedTargets = Get-BootstrapResolvedSecretsTargets -SecretsData $secretsData -IncludeManagedMcps
    $editorTargets = Get-BootstrapVsCodeEditorTargets
    $extensionCatalog = Get-BootstrapVsCodeExtensionCatalog
    $statePath = Get-BootstrapVsCodeExtensionStatePath

    $summary = [ordered]@{
        path = $statePath
        generatedAt = (Get-Date).ToString('o')
        editors = [ordered]@{}
        continue = [ordered]@{}
        authPending = @()
        extensions = @()
    }

    $agentMemorySettings = @{
        'agentMemory.storageBackend' = 'secret'
        'agentMemory.autoSyncToFile' = ''
    }

    foreach ($channel in @($editorTargets.Keys)) {
        $editor = $editorTargets[$channel]
        $editorSummary = [ordered]@{
            displayName = [string]$editor['displayName']
            available = [bool]$editor['available']
            cliPath = [string]$editor['cliPath']
            settingsPath = [string]$editor['settingsPath']
            settingsUpdated = $false
            installed = @()
            failed = @()
        }

        if (-not $editorSummary.available) {
            Write-Log ("Editor ausente, extensoes serao ignoradas: {0}" -f $editorSummary.displayName) 'WARN'
            $summary.editors[$channel] = $editorSummary
            continue
        }

        $installedExtensions = @(Get-BootstrapInstalledVsCodeExtensions -CliPath $editorSummary.cliPath)
        foreach ($extensionId in $extensionCatalog.Keys) {
            $definition = $extensionCatalog[$extensionId]
            if (-not (@($definition['channels']) -contains $channel)) { continue }

            $installResult = Ensure-BootstrapVsCodeExtensionInstalled -CliPath $editorSummary.cliPath -ExtensionDefinition $definition -InstalledExtensions $installedExtensions -EditorLabel $editorSummary.displayName
            $record = [ordered]@{
                editor = $editorSummary.displayName
                extensionId = [string]$definition['id']
                displayName = [string]$definition['displayName']
                installed = [bool]$installResult['installed']
                changed = [bool]$installResult['changed']
                configKind = [string]$definition['configKind']
                error = [string]$installResult['error']
            }

            if ($record.installed) {
                $editorSummary.installed += @([string]$record.extensionId)
                if ($record.changed) {
                    $installedExtensions += @([string]$record.extensionId)
                }
            } else {
                $editorSummary.failed += @([string]$record.extensionId)
            }

            $summary.extensions += @($record)
        }

        $editorSummary.settingsUpdated = Ensure-BootstrapJsonPropertyFile -Path $editorSummary.settingsPath -Values $agentMemorySettings -Label ($editorSummary.displayName + ' settings.json')
        $summary.editors[$channel] = $editorSummary
    }

    if ($resolvedTargets.ContainsKey('roo') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['roo'])) {
        $null = Ensure-BootstrapRooSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('cline') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['cline'])) {
        $null = Ensure-BootstrapClineSecrets -ResolvedTargets $resolvedTargets
    }

    $summary.continue = Ensure-BootstrapContinueExtensionConfig -ResolvedTargets $resolvedTargets
    foreach ($definition in $extensionCatalog.Values) {
        if ([string]::IsNullOrWhiteSpace([string]$definition['authPendingReason'])) { continue }
        $summary.authPending += @([ordered]@{
            extensionId = [string]$definition['id']
            displayName = [string]$definition['displayName']
            reason = [string]$definition['authPendingReason']
        })
    }

    Write-BootstrapJsonFile -Path $statePath -Value $summary
    Write-Log ("Estado local de extensoes VS Code sincronizado: {0}" -f $statePath)

    $State.VsCodeExtensionsPath = $statePath
    $State.VsCodeExtensionsSummary = $summary
    return $summary
}

function Ensure-BootstrapSecrets {
    param([hashtable]$State)

    $bundle = Get-BootstrapSecretsData
    $validatedData = Invoke-BootstrapSecretsValidation -SecretsData $bundle.Data
    Write-BootstrapJsonFile -Path $bundle.Path -Value $validatedData
    $resolvedTargets = Get-BootstrapResolvedSecretsTargets -SecretsData $validatedData
    $diagnostics = Get-BootstrapSecretsDiagnostics -SecretsData $validatedData
    $summary = [ordered]@{
        path = [string]$bundle['Path']
        createdTemplate = $bundle.Created
        userEnvApplied = 0
        claudeCodeUpdated = $false
        claudeDesktopUpdated = $false
        cursorUpdated = $false
        windsurfUpdated = $false
        traeUpdated = $false
        openCodeUpdated = $false
        vsCodeUpdated = $false
        rooUpdated = $false
        clineUpdated = $false
        zedUpdated = $false
        zCodeUpdated = $false
        openClawUpdated = $false
        cometUpdated = $false
        diagnostics = $diagnostics
    }

    if ($resolvedTargets.ContainsKey('userEnv') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['userEnv'])) {
        $summary.userEnvApplied = Ensure-BootstrapUserEnvSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('claudeCode') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['claudeCode'])) {
        $summary.claudeCodeUpdated = Ensure-BootstrapClaudeCodeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('claudeDesktop') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['claudeDesktop'])) {
        $summary.claudeDesktopUpdated = Ensure-BootstrapClaudeDesktopSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('cursor') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['cursor'])) {
        $summary.cursorUpdated = Ensure-BootstrapCursorSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('windsurf') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['windsurf'])) {
        $summary.windsurfUpdated = Ensure-BootstrapWindsurfSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('trae') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['trae'])) {
        $summary.traeUpdated = Ensure-BootstrapTraeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('openCode') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['openCode'])) {
        $summary.openCodeUpdated = Ensure-BootstrapOpenCodeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('vsCode') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['vsCode'])) {
        $summary.vsCodeUpdated = Ensure-BootstrapVsCodeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('roo') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['roo'])) {
        $summary.rooUpdated = Ensure-BootstrapRooSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('cline') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['cline'])) {
        $summary.clineUpdated = Ensure-BootstrapClineSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('zed') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['zed'])) {
        $summary.zedUpdated = Ensure-BootstrapZedSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('zCode') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['zCode'])) {
        $summary.zCodeUpdated = Ensure-BootstrapZCodeSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('openClaw') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['openClaw'])) {
        $summary.openClawUpdated = Ensure-BootstrapOpenClawSecrets -ResolvedTargets $resolvedTargets
    }
    if ($resolvedTargets.ContainsKey('comet') -and (Test-BootstrapSecretsTargetHasApplicableValues -Target $resolvedTargets['comet'])) {
        $summary.cometUpdated = Ensure-BootstrapCometSecrets -ResolvedTargets $resolvedTargets
    }

    $State.SecretsPath = [string]$bundle['Path']
    $State.SecretsSummary = $summary

    foreach ($warning in @($diagnostics.warnings)) {
        Write-Log "Manifesto de segredos: $warning" 'WARN'
    }

    if ($bundle.Created) {
        Write-Log "Manifesto de segredos criado em $($bundle['Path']). Preencha as chaves e rode o bootstrap novamente para propagar tudo automaticamente." 'WARN'
    } else {
        Write-Log ("Manifesto de segredos sincronizado: env={0}, claudeCode={1}, claudeDesktop={2}, cursor={3}, windsurf={4}, trae={5}, openCode={6}, vsCode={7}, roo={8}, cline={9}, zed={10}, zCode={11}, openClaw={12}, comet={13}" -f $summary.userEnvApplied, $summary.claudeCodeUpdated, $summary.claudeDesktopUpdated, $summary.cursorUpdated, $summary.windsurfUpdated, $summary.traeUpdated, $summary.openCodeUpdated, $summary.vsCodeUpdated, $summary.rooUpdated, $summary.clineUpdated, $summary.zedUpdated, $summary.zCodeUpdated, $summary.openClawUpdated, $summary.cometUpdated)
    }
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
        'bootstrap-secrets' { Ensure-BootstrapSecrets -State $State }
        'bootstrap-mcps' { Ensure-BootstrapManagedMcps -State $State | Out-Null }
        'vscode-extensions' { Ensure-BootstrapVsCodeExtensions -State $State | Out-Null }
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
    Invoke-BootstrapExecutionPreflight -State $state -ResolvedComponents $resolution.ResolvedComponents

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
            secretsPath = $state.SecretsPath
            secretsSummary = $state.SecretsSummary
            usesSteamDeckFlow = $usesSteamDeckFlow
            resolvedSteamDeckVersion = $resolvedSteamDeckVersion
            resolvedHostHealthMode = $resolvedHostHealthMode
            selection = $selection
            resolution = $resolution
            hostHealthReportRoot = $state.HostHealthReportRoot
            steamDeckSettingsPath = $state.SteamDeckSettingsPath
            steamDeckAutomationRoot = $state.SteamDeckAutomationRoot
            preflight = $state.PreflightSummary
        })
    }

    Write-Log 'Resumo:'
    if (-not [string]::IsNullOrWhiteSpace($state.SecretsPath)) {
        Write-Log "bootstrap secrets: $($state.SecretsPath)"
    }
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

    $opencodeExe = Join-Path (Join-Path (Get-BootstrapUserHomePath) '.opencode\bin') 'opencode.exe'
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

function Set-BootstrapSecretsPreferredActiveCredentials {
    param(
        [Parameter(Mandatory = $true)]$SecretsData,
        [switch]$ForceFirstPassed,
        [switch]$OnlyWhenMissing
    )

    $normalized = Normalize-BootstrapSecretsData -Secrets $SecretsData

    foreach ($providerName in @($normalized.providers.Keys)) {
        $provider = ConvertTo-BootstrapHashtable -InputObject $normalized.providers[$providerName]
        if (-not ($provider -is [hashtable])) { continue }
        if (-not ($provider.ContainsKey('credentials') -and ($provider['credentials'] -is [hashtable]))) { continue }

        $shouldSelect = $ForceFirstPassed
        if ($OnlyWhenMissing -and [string]::IsNullOrWhiteSpace([string]$provider['activeCredential'])) {
            $shouldSelect = $true
        }
        if (-not $shouldSelect) { continue }

        $candidateIds = @()
        foreach ($credentialId in @($provider['rotationOrder'])) {
            $value = [string]$credentialId
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if ($provider['credentials'].Contains($value)) {
                $candidateIds += @($value)
            }
        }
        foreach ($credentialId in $provider['credentials'].Keys) {
            if ($candidateIds -notcontains [string]$credentialId) {
                $candidateIds += @([string]$credentialId)
            }
        }

        $selected = ''
        foreach ($credentialId in $candidateIds) {
            $credential = ConvertTo-BootstrapHashtable -InputObject $provider['credentials'][$credentialId]
            if (-not ($credential -is [hashtable])) { continue }
            if (($credential.ContainsKey('validation')) -and ($credential['validation'] -is [hashtable]) -and ([string]$credential['validation']['state'] -eq 'passed')) {
                $selected = [string]$credentialId
                break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $provider['activeCredential'] = $selected
        } elseif ($ForceFirstPassed) {
            $provider['activeCredential'] = ''
        }

        $normalized.providers[$providerName] = Convert-BootstrapSecretsProviderDefinition -ProviderName ([string]$providerName) -ProviderData $provider
    }

    return $normalized
}

function Write-BootstrapSecretsList {
    param([Parameter(Mandatory = $true)]$SecretsData)

    foreach ($entry in @(Get-BootstrapSecretsListEntries -SecretsData $SecretsData)) {
        $line = '{0} | {1} | active={2} | state={3} | {4}' -f $entry.provider, $entry.id, $entry.active.ToString().ToLowerInvariant(), $entry.validationState, $entry.displayName
        Write-Output $line
    }
}

function Invoke-BootstrapSecretsMode {
    $bundle = Get-BootstrapSecretsData
    $data = $bundle.Data
    $mutated = $false

    if (-not [string]::IsNullOrWhiteSpace($SecretsImportPath)) {
        $text = Get-Content -Path $SecretsImportPath -Raw -Encoding utf8
        $data = Import-BootstrapSecretsText -Text $text -SecretsData $data
        $data = Invoke-BootstrapSecretsValidation -SecretsData $data -ValidateAll
        $data = Set-BootstrapSecretsPreferredActiveCredentials -SecretsData $data -ForceFirstPassed
        $mutated = $true
    }

    if ($SecretsValidateAll) {
        $data = Invoke-BootstrapSecretsValidation -SecretsData $data -ValidateAll
        $data = Set-BootstrapSecretsPreferredActiveCredentials -SecretsData $data -OnlyWhenMissing
        $mutated = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($SecretsActivateCredential)) {
        if ($SecretsActivateCredential -notmatch '^([a-z0-9]+)-') {
            throw "Nao foi possivel inferir o provider da credencial: $SecretsActivateCredential"
        }
        $providerName = [string]$matches[1]
        $data = Set-BootstrapSecretsActiveCredential -SecretsData $data -ProviderName $providerName -CredentialId $SecretsActivateCredential
        $mutated = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($SecretsActivateProvider)) {
        $data = Move-BootstrapSecretsToNextCredential -SecretsData $data -ProviderName $SecretsActivateProvider.ToLowerInvariant()
        $mutated = $true
    }

    if ($mutated) {
        Write-BootstrapJsonFile -Path $bundle.Path -Value $data
        $state = New-BootstrapState -ResolvedWorkspaceRoot (Get-Location).Path -ResolvedCloneBaseDir (Get-Location).Path -RequestedSteamDeckVersion 'Auto' -ResolvedSteamDeckVersion '' -HostHealthMode 'off' -UsesSteamDeckFlow:$false -IsDryRun:$false
        Ensure-BootstrapSecrets -State $state
        $data = (Read-BootstrapJsonFile -Path $bundle.Path)
    }

    if ($SecretsList) {
        Write-BootstrapSecretsList -SecretsData $data
    }
}

$invocationName = ''
try { $invocationName = [string]$MyInvocation.InvocationName } catch { $invocationName = '' }
$isDotSourced = ($invocationName -eq '.')

$useBootstrapSecretsMode = (
    $SecretsList -or
    $SecretsValidateAll -or
    [string]::IsNullOrWhiteSpace($SecretsImportPath) -eq $false -or
    [string]::IsNullOrWhiteSpace($SecretsActivateProvider) -eq $false -or
    [string]::IsNullOrWhiteSpace($SecretsActivateCredential) -eq $false
)

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

if (-not $isDotSourced) {
    if ($UiContractJson) {
        (Get-BootstrapUiContract | ConvertTo-Json -Depth 12)
        return
    }

    if ($BootstrapUiLibraryMode) {
        return
    }

    if ($useBootstrapSecretsMode) {
        try {
            Invoke-BootstrapSecretsMode
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

        $opencodeExe = Join-Path (Join-Path (Get-BootstrapUserHomePath) '.opencode\bin') 'opencode.exe'
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
}
