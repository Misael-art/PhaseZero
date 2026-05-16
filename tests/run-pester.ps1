param(
    [string]$Path = (Join-Path $PSScriptRoot '*.tests.ps1'),
    [switch]$NoInstall,
    [switch]$LibraryMode,
    [version]$RequiredPesterVersion = ([version]'3.4.0'),
    [ValidateRange(30, 3600)][int]$InstallTimeoutSeconds = 300,
    [ValidateRange(1, 5)][int]$InstallAttempts = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PesterRunnerInstallCommand {
    param([Parameter(Mandatory = $true)][version]$RequiredVersion)

    return ("Install-Module Pester -RequiredVersion {0} -Scope CurrentUser -Repository PSGallery -Force" -f $RequiredVersion)
}

function Get-PesterRunnerAvailableModules {
    return @(Get-Module -ListAvailable -Name Pester)
}

function Get-PesterRunnerInstalledModule {
    param([Parameter(Mandatory = $true)][version]$RequiredVersion)

    return @(Get-PesterRunnerAvailableModules |
        Where-Object { $_.Version -eq $RequiredVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1)
}

function Invoke-PesterRunnerBootstrapStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds = 300,
        [ValidateRange(1, 5)][int]$Attempts = 2
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $job = $null
        try {
            Write-Host ("Bootstrap dependency: {0} (attempt {1}/{2}, timeout {3}s)" -f $Name, $attempt, $Attempts, $TimeoutSeconds)
            $job = Start-Job -ScriptBlock $ScriptBlock
            $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
            if (-not $completed) {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                throw ("{0} timed out after {1}s" -f $Name, $TimeoutSeconds)
            }

            Receive-Job -Job $job -ErrorAction Stop | ForEach-Object { Write-Host $_ }
            return
        } catch {
            $lastError = $_
            if ($attempt -lt $Attempts) {
                Write-Warning ("{0} failed: {1}. Retrying." -f $Name, $_.Exception.Message)
                Start-Sleep -Seconds 2
            }
        } finally {
            if ($job) {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }

    throw ("{0} failed after {1} attempt(s). Last error: {2}" -f $Name, $Attempts, $lastError.Exception.Message)
}

function Resolve-PesterRunnerModule {
    param(
        [Parameter(Mandatory = $true)][version]$RequiredVersion,
        [switch]$NoInstall,
        [ValidateRange(30, 3600)][int]$InstallTimeoutSeconds = 300,
        [ValidateRange(1, 5)][int]$InstallAttempts = 2
    )

    $existing = @(Get-PesterRunnerInstalledModule -RequiredVersion $RequiredVersion)
    if ($existing.Count -gt 0) {
        return $existing[0]
    }

    $installCommand = Get-PesterRunnerInstallCommand -RequiredVersion $RequiredVersion
    if ($NoInstall) {
        throw ("Pester {0} not found. Install with: {1}" -f $RequiredVersion, $installCommand)
    }

    Invoke-PesterRunnerBootstrapStep -Name 'NuGet package provider' -TimeoutSeconds $InstallTimeoutSeconds -Attempts $InstallAttempts -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
    }

    $requiredVersionText = [string]$RequiredVersion
    Invoke-PesterRunnerBootstrapStep -Name ("Pester {0}" -f $requiredVersionText) -TimeoutSeconds $InstallTimeoutSeconds -Attempts $InstallAttempts -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-Module Pester -RequiredVersion $using:requiredVersionText -Scope CurrentUser -Repository PSGallery -Force
    }

    $installed = @(Get-PesterRunnerInstalledModule -RequiredVersion $RequiredVersion)
    if ($installed.Count -eq 0) {
        throw ("Pester {0} install finished but module was not found. Next step: {1}" -f $RequiredVersion, $installCommand)
    }

    return $installed[0]
}

if ($LibraryMode) {
    return
}

$pesterModule = Resolve-PesterRunnerModule -RequiredVersion $RequiredPesterVersion -NoInstall:$NoInstall -InstallTimeoutSeconds $InstallTimeoutSeconds -InstallAttempts $InstallAttempts
Import-Module Pester -RequiredVersion $RequiredPesterVersion -Force
Write-Host ("Using Pester {0} from {1}" -f $pesterModule.Version, $pesterModule.ModuleBase)

$result = Invoke-Pester -Path $Path -PassThru
$passed = [int]$result.PassedCount
$failed = [int]$result.FailedCount
$skipped = [int]$result.SkippedCount
$total = [int]$result.TotalCount

Write-Host ("Pester summary: Passed={0} Failed={1} Skipped={2} Total={3}" -f $passed, $failed, $skipped, $total)

$exitCode = if ($failed -gt 0) { 1 } else { 0 }
[Environment]::Exit($exitCode)
