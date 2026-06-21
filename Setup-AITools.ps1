<# 
.SYNOPSIS
    Zero-touch setup for AI coding assistant tooling on Windows.

.DESCRIPTION
    Installs and validates Node.js/npm/npx, Git, RTK (Rust Token Killer), and
    the Caveman skill. The script is idempotent: reruns reuse existing valid
    tools, repair PATH when needed, and emit explicit diagnostics.

    Default install root:
        $env:USERPROFILE\.local

    Managed binary directory:
        $env:USERPROFILE\.local\bin

    The script changes ExecutionPolicy only for CurrentUser/Process and never
    logs secrets.
#>
[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.local'),
    [string]$LogPath = '',
    [int]$CommandTimeoutSeconds = 600,
    [int]$InstallTimeoutSeconds = 600,
    [switch]$NoColor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:StartedAt = Get-Date
$script:Rows = New-Object System.Collections.Generic.List[object]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Failures = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDir = Join-Path $env:USERPROFILE '.setup-ai-tools\logs'
    $LogPath = Join-Path $logDir ("Setup-AITools_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function New-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }
}

New-Directory -Path (Split-Path -Parent $LogPath)

function Write-SetupLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8

    if ($NoColor) {
        Write-Host $line
        return
    }

    $color = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Add-SetupRow {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Message = '',
        [string]$Detail = ''
    )

    $script:Rows.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Message = $Message
        Detail = $Detail
    })
}

function Add-Warning {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Warnings.Add($Message)
    Write-SetupLog -Level WARN -Message $Message
}

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Failures.Add($Message)
    Write-SetupLog -Level ERROR -Message $Message
}

function ConvertTo-WindowsCommandLine {
    param([string[]]$Arguments = @())

    $quoted = foreach ($arg in @($Arguments)) {
        $value = [string]$arg
        if ($value.Length -eq 0) {
            '""'
            continue
        }
        if ($value -notmatch '[\s"]') {
            $value
            continue
        }

        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($ch in $value.ToCharArray()) {
            if ($ch -eq '\') {
                $backslashes++
                continue
            }
            if ($ch -eq '"') {
                [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
                [void]$builder.Append('"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                [void]$builder.Append(('\' * $backslashes))
                $backslashes = 0
            }
            [void]$builder.Append($ch)
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * ($backslashes * 2)))
        }
        [void]$builder.Append('"')
        [string]$builder.ToString()
    }

    return ($quoted -join ' ')
}

function Resolve-CommandPath {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [string[]]$PreferredExtensions = @('.exe','.cmd','.bat','.ps1')
    )

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Names) {
        foreach ($cmd in @(Get-Command -Name $name -All -ErrorAction SilentlyContinue)) {
            if ($cmd.Source) {
                $matches.Add([pscustomobject]@{ Name = $cmd.Name; Path = [string]$cmd.Source })
            }
        }
    }

    foreach ($ext in $PreferredExtensions) {
        $hit = @($matches | Where-Object { [System.IO.Path]::GetExtension([string]$_.Path) -ieq $ext } | Select-Object -First 1)
        if ($hit) { return [string]$hit[0].Path }
    }

    if ($matches.Count -gt 0) { return [string]$matches[0].Path }
    return ''
}

function Invoke-CommandChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = $CommandTimeoutSeconds,
        [int[]]$SuccessExitCodes = @(0),
        [string]$InputText = ''
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-WindowsCommandLine -Arguments $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = -not [string]::IsNullOrEmpty($InputText)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    Write-SetupLog ("exec: {0} {1}" -f $FilePath, $psi.Arguments)
    [void]$proc.Start()

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not [string]::IsNullOrEmpty($InputText)) {
        $proc.StandardInput.Write($InputText)
        $proc.StandardInput.Close()
    }

    $timeoutMs = [Math]::Max(1, $TimeoutSeconds) * 1000
    $timedOut = -not $proc.WaitForExit($timeoutMs)
    if ($timedOut) {
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit(5000) } catch { }
    } else {
        try { $proc.WaitForExit() } catch { }
    }

    $exitCode = if ($timedOut) { 124 } else { [int]$proc.ExitCode }
    $stdout = ''
    $stderr = ''
    try { $stdout = [string]$stdoutTask.Result } catch { }
    try { $stderr = [string]$stderrTask.Result } catch { }
    try { $proc.Dispose() } catch { }

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        foreach ($line in (($stdout -replace "`r", '') -split "`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-SetupLog ("stdout: {0}" -f $line) }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        foreach ($line in (($stderr -replace "`r", '') -split "`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-SetupLog ("stderr: {0}" -f $line) 'WARN' }
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        Succeeded = ($SuccessExitCodes -contains $exitCode)
        Stdout = $stdout
        Stderr = $stderr
        FilePath = $FilePath
        Arguments = @($Arguments)
    }
}

function Refresh-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

function Ensure-UserPathContains {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $dir = $Directory.Trim().TrimEnd('\')
    New-Directory -Path $dir

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) { $userPath = '' }

    $parts = @($userPath -split ';' | ForEach-Object { ([string]$_).Trim().TrimEnd('\') } | Where-Object { $_ })
    if ($parts -inotcontains $dir) {
        $newPath = (@($parts) + $dir) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-SetupLog ("PATH User atualizado: {0}" -f $dir)
    } else {
        Write-SetupLog ("PATH User ja contem: {0}" -f $dir)
    }

    Refresh-SessionPath
    if (($env:Path -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') }) -inotcontains $dir) {
        $env:Path = ($env:Path.TrimEnd(';') + ';' + $dir).Trim(';')
    }
}

function Ensure-ExecutionPolicy {
    try {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
        $currentUserPolicy = Get-ExecutionPolicy -Scope CurrentUser
        if ($currentUserPolicy -in @('Restricted','AllSigned','Undefined')) {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
            Add-SetupRow -Name 'ExecutionPolicy' -Status 'changed' -Message 'CurrentUser set to RemoteSigned; Process set to Bypass.'
        } else {
            Add-SetupRow -Name 'ExecutionPolicy' -Status 'ok' -Message ("CurrentUser={0}; Process=Bypass" -f $currentUserPolicy)
        }
    } catch {
        Add-Warning ("ExecutionPolicy nao alterada: {0}. Continuando com chamadas PowerShell -ExecutionPolicy Bypass quando necessario." -f $_.Exception.Message)
        Add-SetupRow -Name 'ExecutionPolicy' -Status 'warning' -Message $_.Exception.Message
    }
}

function Get-WingetPath {
    $winget = Resolve-CommandPath -Names @('winget.exe','winget')
    if ([string]::IsNullOrWhiteSpace($winget)) {
        throw 'winget nao encontrado. Instale/atualize App Installer pela Microsoft Store e execute novamente.'
    }
    return $winget
}

function Test-CommandVersion {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [string[]]$VersionArgs = @('--version'),
        [int]$TimeoutSeconds = 60
    )

    $path = Resolve-CommandPath -Names $Names
    if ([string]::IsNullOrWhiteSpace($path)) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Version = ''; Error = 'command not found' }
    }

    $result = Invoke-CommandChecked -FilePath $path -Arguments $VersionArgs -TimeoutSeconds $TimeoutSeconds
    $text = (($result.Stdout + "`n" + $result.Stderr) -replace "`r", '').Trim()
    return [pscustomobject]@{
        Ok = $result.Succeeded
        Path = $path
        Version = $text
        Error = if ($result.Succeeded) { '' } else { "exit=$($result.ExitCode)" }
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string[]]$CommandsToValidate = @()
    )

    if ($CommandsToValidate.Count -gt 0) {
        $allFound = $true
        foreach ($cmd in $CommandsToValidate) {
            if ([string]::IsNullOrWhiteSpace((Resolve-CommandPath -Names @($cmd)))) {
                $allFound = $false
                break
            }
        }
        if ($allFound) {
            Write-SetupLog ("{0} ja presente no PATH." -f $DisplayName)
            return
        }
    }

    $winget = Get-WingetPath
    $baseArgs = @(
        'install',
        '-e',
        '--id', $Id,
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity',
        '--silent'
    )

    $attempts = @(
        @($baseArgs + @('--scope', 'user')),
        @($baseArgs)
    )

    $last = $null
    foreach ($args in $attempts) {
        $last = Invoke-CommandChecked -FilePath $winget -Arguments $args -TimeoutSeconds $InstallTimeoutSeconds -SuccessExitCodes @(0, -1978335189, -1978335215)
        Refresh-SessionPath
        if ($last.Succeeded) { break }
    }

    if (-not $last -or -not $last.Succeeded) {
        throw ("winget install falhou para {0}. Exit={1}. Veja log: {2}" -f $DisplayName, $last.ExitCode, $LogPath)
    }
}

function Ensure-Node {
    $node = Test-CommandVersion -Names @('node.exe','node') -VersionArgs @('--version')
    $npm = Test-CommandVersion -Names @('npm.cmd','npm.exe','npm') -VersionArgs @('--version')
    $npx = Test-CommandVersion -Names @('npx.cmd','npx.exe','npx') -VersionArgs @('--version')

    if ($node.Ok -and $npm.Ok -and $npx.Ok) {
        Add-SetupRow -Name 'Node.js/npm/npx' -Status 'ok' -Message (($node.Version, $npm.Version, $npx.Version) -join ' / ') -Detail $node.Path
        return
    }

    Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -DisplayName 'Node.js LTS' -CommandsToValidate @('node','npm','npx')
    Refresh-SessionPath

    $node = Test-CommandVersion -Names @('node.exe','node') -VersionArgs @('--version')
    $npm = Test-CommandVersion -Names @('npm.cmd','npm.exe','npm') -VersionArgs @('--version')
    $npx = Test-CommandVersion -Names @('npx.cmd','npx.exe','npx') -VersionArgs @('--version')
    if (-not ($node.Ok -and $npm.Ok -and $npx.Ok)) {
        throw 'Node.js/npm/npx continuaram indisponiveis apos winget install.'
    }

    Add-SetupRow -Name 'Node.js/npm/npx' -Status 'installed' -Message (($node.Version, $npm.Version, $npx.Version) -join ' / ') -Detail $node.Path
}

function Ensure-Git {
    $git = Test-CommandVersion -Names @('git.exe','git') -VersionArgs @('--version')
    if ($git.Ok) {
        Add-SetupRow -Name 'Git' -Status 'ok' -Message $git.Version -Detail $git.Path
        return
    }

    Install-WingetPackage -Id 'Git.Git' -DisplayName 'Git' -CommandsToValidate @('git')
    Refresh-SessionPath
    $git = Test-CommandVersion -Names @('git.exe','git') -VersionArgs @('--version')
    if (-not $git.Ok) { throw 'Git continuou indisponivel apos winget install.' }
    Add-SetupRow -Name 'Git' -Status 'installed' -Message $git.Version -Detail $git.Path
}

function Get-RtkBinDir {
    return (Join-Path $InstallRoot 'bin')
}

function Install-Rtk {
    $existing = Test-CommandVersion -Names @('rtk.exe','rtk') -VersionArgs @('--version') -TimeoutSeconds 60
    if ($existing.Ok) {
        Add-SetupRow -Name 'RTK' -Status 'ok' -Message $existing.Version -Detail $existing.Path
        return
    }

    $binDir = Get-RtkBinDir
    Ensure-UserPathContains -Directory $binDir
    $rtkExe = Join-Path $binDir 'rtk.exe'
    if (Test-Path -LiteralPath $rtkExe) {
        Refresh-SessionPath
        $existing = Test-CommandVersion -Names @('rtk.exe','rtk') -VersionArgs @('--version') -TimeoutSeconds 60
        if ($existing.Ok) {
            Add-SetupRow -Name 'RTK' -Status 'path-repaired' -Message $existing.Version -Detail $existing.Path
            return
        }
    }

    $api = 'https://api.github.com/repos/rtk-ai/rtk/releases/latest'
    Write-SetupLog "RTK: consultando release GitHub: $api"
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'PhaseZero-Setup-AITools' } -ErrorAction Stop
    $assets = @($release.assets)
    $asset = @(
        $assets | Where-Object {
            ([string]$_.name) -match '(?i)x86_64.*windows.*\.zip$|pc-windows.*\.zip$|win.*\.zip$'
        } | Select-Object -First 1
    )

    if (-not $asset) {
        throw 'RTK release oficial nao publicou asset Windows .zip detectavel.'
    }

    New-Directory -Path $binDir
    $downloadDir = Join-Path $InstallRoot 'downloads\rtk'
    New-Directory -Path $downloadDir

    $assetPath = Join-Path $downloadDir ([string]$asset[0].name)
    Write-SetupLog ("RTK: baixando {0}" -f $asset[0].browser_download_url)
    Invoke-WebRequest -Uri ([string]$asset[0].browser_download_url) -OutFile $assetPath -UseBasicParsing -Headers @{ 'User-Agent' = 'PhaseZero-Setup-AITools' } -ErrorAction Stop

    $checksumAsset = @(
        $assets | Where-Object { ([string]$_.name) -ieq 'checksums.txt' -or ([string]$_.name) -ieq 'SHA256SUMS' -or ([string]$_.name) -ieq (([string]$asset[0].name) + '.sha256') } |
            Select-Object -First 1
    )
    if ($checksumAsset) {
        $checksumPath = Join-Path $downloadDir ([string]$checksumAsset[0].name)
        Invoke-WebRequest -Uri ([string]$checksumAsset[0].browser_download_url) -OutFile $checksumPath -UseBasicParsing -Headers @{ 'User-Agent' = 'PhaseZero-Setup-AITools' } -ErrorAction Stop
        $text = Get-Content -LiteralPath $checksumPath -Raw
        $expected = ''
        foreach ($line in (($text -replace "`r", '') -split "`n")) {
            if ($line -match [regex]::Escape([string]$asset[0].name)) {
                $expected = ([regex]::Match($line, '(?i)\b[a-f0-9]{64}\b')).Value
                if ($expected) { break }
            }
        }
        if (-not $expected) {
            $expected = ([regex]::Match($text, '(?i)\b[a-f0-9]{64}\b')).Value
        }
        if ($expected) {
            $actual = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $expected.ToLowerInvariant()) {
                throw ("RTK checksum invalido. Esperado={0} Atual={1}" -f $expected, $actual)
            }
            Write-SetupLog "RTK: checksum SHA256 validado."
        } else {
            Add-Warning 'RTK: checksum asset encontrado, mas hash especifico nao foi parseado; continuando com download HTTPS GitHub.'
        }
    } else {
        Add-Warning 'RTK: release sem checksum publicado; continuando com download HTTPS GitHub.'
    }

    $extractDir = Join-Path $downloadDir ([System.IO.Path]::GetFileNameWithoutExtension([string]$asset[0].name))
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $assetPath -DestinationPath $extractDir -Force
    $found = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'rtk.exe' -File | Select-Object -First 1)
    if (-not $found) {
        throw 'RTK zip baixado, mas rtk.exe nao foi encontrado.'
    }

    Copy-Item -LiteralPath $found[0].FullName -Destination $rtkExe -Force
    try { Unblock-File -LiteralPath $rtkExe -ErrorAction SilentlyContinue } catch { }
    Ensure-UserPathContains -Directory $binDir

    $rtk = Test-CommandVersion -Names @('rtk.exe','rtk') -VersionArgs @('--version') -TimeoutSeconds 60
    if (-not $rtk.Ok) {
        throw ("RTK instalado em {0}, mas validacao falhou: {1}" -f $rtkExe, $rtk.Error)
    }

    Add-SetupRow -Name 'RTK' -Status 'installed' -Message $rtk.Version -Detail $rtk.Path
}

function Ensure-SkillsCli {
    $skills = Test-CommandVersion -Names @('skills.cmd','skills.exe','skills') -VersionArgs @('--version')
    if ($skills.Ok) {
        Add-SetupRow -Name 'skills CLI' -Status 'ok' -Message $skills.Version -Detail $skills.Path
        return
    }

    $npm = Resolve-CommandPath -Names @('npm.cmd','npm.exe','npm')
    if ([string]::IsNullOrWhiteSpace($npm)) { throw 'npm nao encontrado para instalar skills CLI.' }

    $install = Invoke-CommandChecked -FilePath $npm -Arguments @('install','-g','skills') -TimeoutSeconds $InstallTimeoutSeconds
    if (-not $install.Succeeded) {
        throw ("npm install -g skills falhou. Exit={0}" -f $install.ExitCode)
    }

    $prefix = Invoke-CommandChecked -FilePath $npm -Arguments @('config','get','prefix') -TimeoutSeconds 60
    if ($prefix.Succeeded) {
        $prefixPath = (($prefix.Stdout -replace "`r", '') -split "`n" | Select-Object -First 1).Trim()
        if ($prefixPath) { Ensure-UserPathContains -Directory $prefixPath }
    }
    Refresh-SessionPath

    $skills = Test-CommandVersion -Names @('skills.cmd','skills.exe','skills') -VersionArgs @('--version')
    if (-not $skills.Ok) {
        throw 'skills CLI continuou indisponivel apos npm install -g skills.'
    }
    Add-SetupRow -Name 'skills CLI' -Status 'installed' -Message $skills.Version -Detail $skills.Path
}

function Install-CavemanSkill {
    Ensure-SkillsCli

    $existing = Test-CavemanSkill
    if ($existing.Ok) {
        Add-SetupRow -Name 'Caveman skill' -Status 'ok' -Message $existing.Message -Detail $existing.Detail
        $codexSync = Sync-CodexCavemanSkill
        if (-not $codexSync.Ok) {
            throw ("Caveman Codex sync falhou: {0}" -f $codexSync.Message)
        }
        Add-SetupRow -Name 'Caveman Codex skill' -Status 'ok' -Message $codexSync.Message -Detail $codexSync.Detail
        return
    }

    $npx = Resolve-CommandPath -Names @('npx.cmd','npx.exe','npx')
    if ([string]::IsNullOrWhiteSpace($npx)) { throw 'npx nao encontrado para instalar Caveman.' }

    # Primary command requested by the spec. It may not exist in npm; keep log and fallback.
    $primary = Invoke-CommandChecked -FilePath $npx -Arguments @('-y','@methexis/skills','add','caveman','-g','-y') -TimeoutSeconds $InstallTimeoutSeconds
    if (-not $primary.Succeeded) {
        Add-Warning ("Caveman: comando primario @methexis/skills falhou (exit={0}); usando fallback skills/JuliusBrussee." -f $primary.ExitCode)
    }

    $skills = Resolve-CommandPath -Names @('skills.cmd','skills.exe','skills')
    $fallback = Invoke-CommandChecked -FilePath $skills -Arguments @('add','JuliusBrussee/caveman','-g','-y','--copy') -TimeoutSeconds $InstallTimeoutSeconds -SuccessExitCodes @(0)
    if (-not $fallback.Succeeded) {
        $npxFallback = Invoke-CommandChecked -FilePath $npx -Arguments @('-y','skills','add','JuliusBrussee/caveman','-g','-y','--copy') -TimeoutSeconds $InstallTimeoutSeconds
        if (-not $npxFallback.Succeeded) {
            throw ("Caveman install falhou nos fallbacks. skills exit={0}; npx skills exit={1}" -f $fallback.ExitCode, $npxFallback.ExitCode)
        }
    }

    Add-SetupRow -Name 'Caveman skill' -Status 'installed-or-updated' -Message 'Global skill install command completed.' -Detail 'JuliusBrussee/caveman'

    $codexSync = Sync-CodexCavemanSkill
    if (-not $codexSync.Ok) {
        throw ("Caveman Codex sync falhou: {0}" -f $codexSync.Message)
    }
    Add-SetupRow -Name 'Caveman Codex skill' -Status 'installed-or-updated' -Message $codexSync.Message -Detail $codexSync.Detail
}

function Sync-CodexCavemanSkill {
    $sourceRoot = Join-Path $env:USERPROFILE '.agents\skills\caveman'
    $destinationRoot = Join-Path $env:USERPROFILE '.codex\skills\caveman'
    $sourceSkill = Join-Path $sourceRoot 'SKILL.md'
    $destinationSkill = Join-Path $destinationRoot 'SKILL.md'

    if (-not (Test-Path -LiteralPath $sourceSkill)) {
        return [pscustomobject]@{ Ok = $false; Message = 'Origem Caveman global nao encontrada.'; Detail = $sourceSkill }
    }

    New-Directory -Path (Split-Path -Parent $destinationRoot)
    New-Directory -Path $destinationRoot

    Get-ChildItem -LiteralPath $sourceRoot -Force | Copy-Item -Destination $destinationRoot -Recurse -Force

    if (-not (Test-Path -LiteralPath $destinationSkill)) {
        return [pscustomobject]@{ Ok = $false; Message = 'SKILL.md nao apareceu no destino Codex.'; Detail = $destinationSkill }
    }

    return [pscustomobject]@{ Ok = $true; Message = 'Caveman espelhado para Codex Desktop.'; Detail = $destinationSkill }
}

function Test-CodexCavemanSkill {
    $skillPath = Join-Path $env:USERPROFILE '.codex\skills\caveman\SKILL.md'
    if (Test-Path -LiteralPath $skillPath) {
        return [pscustomobject]@{ Ok = $true; Message = 'Caveman encontrado em ~/.codex/skills.'; Detail = $skillPath }
    }

    return [pscustomobject]@{ Ok = $false; Message = 'Caveman ausente em ~/.codex/skills.'; Detail = $skillPath }
}

function Test-CavemanSkill {
    $skills = Resolve-CommandPath -Names @('skills.cmd','skills.exe','skills')
    if ([string]::IsNullOrWhiteSpace($skills)) {
        return [pscustomobject]@{ Ok = $false; Message = 'skills CLI nao encontrado no PATH.'; Detail = '' }
    }

    $list = Invoke-CommandChecked -FilePath $skills -Arguments @('list','-g','--json') -TimeoutSeconds 120
    $raw = (($list.Stdout + "`n" + $list.Stderr) -replace "`r", '')
    if (-not $list.Succeeded) {
        return [pscustomobject]@{ Ok = $false; Message = ("skills list -g falhou: exit={0}" -f $list.ExitCode); Detail = $raw.Trim() }
    }

    if ($raw -match '(?i)caveman|JuliusBrussee/caveman') {
        return [pscustomobject]@{ Ok = $true; Message = 'Caveman listado em skills global.'; Detail = $raw.Trim() }
    }

    $knownRoots = @(
        (Join-Path $env:USERPROFILE '.codex\skills'),
        (Join-Path $env:USERPROFILE '.claude\skills'),
        (Join-Path $env:APPDATA 'Claude\skills')
    )
    foreach ($root in $knownRoots) {
        if (Test-Path -LiteralPath $root) {
            $hit = @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'SKILL.md' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '(?i)caveman' } | Select-Object -First 1)
            if ($hit) {
                return [pscustomobject]@{ Ok = $true; Message = 'Caveman encontrado em diretorio de skills.'; Detail = $hit[0].FullName }
            }
        }
    }

    return [pscustomobject]@{ Ok = $false; Message = 'Caveman nao apareceu em skills list -g --json.'; Detail = $raw.Trim() }
}

function Invoke-Validation {
    Write-SetupLog 'Validacao final iniciada.'

    $checks = @(
        @{ Name = 'node'; Test = { Test-CommandVersion -Names @('node.exe','node') -VersionArgs @('--version') } },
        @{ Name = 'npm'; Test = { Test-CommandVersion -Names @('npm.cmd','npm.exe','npm') -VersionArgs @('--version') } },
        @{ Name = 'npx'; Test = { Test-CommandVersion -Names @('npx.cmd','npx.exe','npx') -VersionArgs @('--version') } },
        @{ Name = 'git'; Test = { Test-CommandVersion -Names @('git.exe','git') -VersionArgs @('--version') } },
        @{ Name = 'rtk'; Test = { Test-CommandVersion -Names @('rtk.exe','rtk') -VersionArgs @('--version') } },
        @{ Name = 'skills'; Test = { Test-CommandVersion -Names @('skills.cmd','skills.exe','skills') -VersionArgs @('--version') } }
    )

    foreach ($check in $checks) {
        $result = & $check.Test
        if ($result.Ok) {
            Add-SetupRow -Name ("validate:{0}" -f $check.Name) -Status 'ok' -Message $result.Version -Detail $result.Path
        } else {
            Add-Failure ("Validacao falhou: {0}: {1}" -f $check.Name, $result.Error)
            Add-SetupRow -Name ("validate:{0}" -f $check.Name) -Status 'failed' -Message $result.Error -Detail $result.Path
        }
    }

    $caveman = Test-CavemanSkill
    if ($caveman.Ok) {
        Add-SetupRow -Name 'validate:caveman' -Status 'ok' -Message $caveman.Message -Detail $caveman.Detail
    } else {
        Add-Failure ("Validacao falhou: caveman: {0}" -f $caveman.Message)
        Add-SetupRow -Name 'validate:caveman' -Status 'failed' -Message $caveman.Message -Detail $caveman.Detail
    }

    $codexCaveman = Test-CodexCavemanSkill
    if ($codexCaveman.Ok) {
        Add-SetupRow -Name 'validate:codex-caveman' -Status 'ok' -Message $codexCaveman.Message -Detail $codexCaveman.Detail
    } else {
        Add-Failure ("Validacao falhou: codex-caveman: {0}" -f $codexCaveman.Message)
        Add-SetupRow -Name 'validate:codex-caveman' -Status 'failed' -Message $codexCaveman.Message -Detail $codexCaveman.Detail
    }
}

function Write-FinalReport {
    $elapsed = New-TimeSpan -Start $script:StartedAt -End (Get-Date)
    Write-Host ''
    Write-Host '=== Setup-AITools report ===' -ForegroundColor Cyan
    $script:Rows | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host ("Log: {0}" -f $LogPath)
    Write-Host ("Elapsed: {0:c}" -f $elapsed)

    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'Warnings:' -ForegroundColor Yellow
        foreach ($w in $script:Warnings) { Write-Host ("- {0}" -f $w) -ForegroundColor Yellow }
    }

    if ($script:Failures.Count -gt 0) {
        Write-Host ''
        Write-Host 'ERROR: AI tooling setup failed.' -ForegroundColor Red
        foreach ($f in $script:Failures) { Write-Host ("- {0}" -f $f) -ForegroundColor Red }
        return 1
    }

    Write-Host ''
    Write-Host 'SUCCESS: AI tooling validated. RTK and Caveman infrastructure ready.' -ForegroundColor Green
    return 0
}

function Invoke-AIToolsSetup {
    [CmdletBinding()]
    param(
        [switch]$ValidateOnly,
        [string]$InstallRoot = (Join-Path $env:USERPROFILE '.local')
    )

    $script:StartedAt = Get-Date
    $script:Rows = New-Object System.Collections.Generic.List[object]
    $script:Warnings = New-Object System.Collections.Generic.List[string]
    $script:Failures = New-Object System.Collections.Generic.List[string]
    $exitCode = 1

    try {
        Write-SetupLog ("Inicio Setup-AITools. ValidateOnly={0}; InstallRoot={1}" -f [bool]$ValidateOnly, $InstallRoot)
        New-Directory -Path $InstallRoot
        Ensure-ExecutionPolicy
        Refresh-SessionPath

        if (-not $ValidateOnly) {
            Ensure-Node
            Ensure-Git
            Install-Rtk
            Install-CavemanSkill
        }

        Invoke-Validation
    } catch {
        Add-Failure $_.Exception.Message
        try {
            Add-Content -LiteralPath $LogPath -Value ($_.ScriptStackTrace) -Encoding utf8
        } catch { }
    } finally {
        $exitCode = Write-FinalReport
    }

    return $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-AIToolsSetup -ValidateOnly:$ValidateOnly -InstallRoot $InstallRoot)
}
