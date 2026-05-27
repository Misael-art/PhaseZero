$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $scriptPath
Reset-BootstrapFileCmdlets

function New-SupportTestRoot {
    return (Join-Path $env:TEMP ("phasezero_support_{0}" -f ([Guid]::NewGuid().ToString('N'))))
}

function Invoke-SupportBootstrap {
    param([string[]]$CommandArgs)

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $CommandArgs
    $quotedArgs = foreach ($arg in $allArgs) {
        if ($arg -match '[\s"]') {
            '"' + ($arg -replace '"', '\"') + '"'
        } else {
            $arg
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellExe
    $startInfo.Arguments = [string]::Join(' ', $quotedArgs)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start bootstrap process for args: $($CommandArgs -join ' ')"
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill() } catch { Write-Verbose $_.Exception.Message }
        throw "Bootstrap invocation timed out for args: $($CommandArgs -join ' ')"
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = @($stdoutTask.Result, $stderrTask.Result) -join [Environment]::NewLine
    }
}

Describe 'PhaseZero support robustness track' {
    BeforeEach {
        $script:SupportTestRoot = New-SupportTestRoot
        $null = New-Item -Path $script:SupportTestRoot -ItemType Directory -Force
    }

    AfterEach {
        Remove-Item -LiteralPath $script:SupportTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name SupportTestRoot -ErrorAction SilentlyContinue
    }

    It 'exposes support capabilities and public-beta in the UI contract' {
        $contract = Get-BootstrapUiContract

        [string]$contract.schemaVersion | Should Be '1.4.0'
        [bool]$contract.capabilities.doctor | Should Be $true
        [bool]$contract.capabilities.supportBundle | Should Be $true
        [bool]$contract.capabilities.repairPlan | Should Be $true
        [bool]$contract.capabilities.publicBetaProfile | Should Be $true
        [bool]$contract.capabilities.steamDeckDoctor | Should Be $true
        [bool]$contract.capabilities.githubCliAgentAuth | Should Be $true
        [bool]$contract.capabilities.aionuiIntegration | Should Be $true
        (@($contract.profileNames) -contains 'public-beta') | Should Be $true
    }

    It 'reports GitHub CLI auth healthy when gh auth status succeeds' {
        Mock Resolve-CommandPath { return 'C:\Tools\gh.exe' } -ParameterFilter { $Name -eq 'gh' }
        Mock Invoke-BootstrapDoctorCommandProbe {
            return [ordered]@{
                id = 'github-cli-auth'
                status = 'healthy'
                severity = 'info'
                path = 'C:\Tools\gh.exe'
                exitCode = 0
                durationMs = 12
                timedOut = $false
                summary = 'Logged in to github.com'
            }
        } -ParameterFilter { $CommandName -eq 'gh' -and ((@($CommandArgs) -join ' ') -eq 'auth status') }

        $check = Get-BootstrapGithubCliAuthHealth -SecretsData @{ providers = @{}; targets = @{} }

        [string]$check.status | Should Be 'healthy'
        [string]$check.ghAuthStatus | Should Be 'authenticated'
        [bool]$check.ghInstalled | Should Be $true
        Assert-MockCalled Invoke-BootstrapDoctorCommandProbe -Times 1 -Exactly
    }

    It 'reports token available when gh is unauthenticated but an active GitHub credential exists' {
        Mock Resolve-CommandPath { return 'C:\Tools\gh.exe' } -ParameterFilter { $Name -eq 'gh' }
        Mock Invoke-BootstrapDoctorCommandProbe {
            return [ordered]@{
                id = 'github-cli-auth'
                status = 'warning'
                severity = 'warning'
                path = 'C:\Tools\gh.exe'
                exitCode = 1
                durationMs = 20
                timedOut = $false
                summary = 'You are not logged into any GitHub hosts.'
            }
        } -ParameterFilter { $CommandName -eq 'gh' -and ((@($CommandArgs) -join ' ') -eq 'auth status') }
        $fixture = @{
            providers = @{
                github = @{
                    activeCredential = 'github-main-01'
                    rotationOrder = @('github-main-01')
                    credentials = @{
                        'github-main-01' = @{
                            displayName = 'Main GitHub'
                            secretKind = 'token'
                            secret = 'ghp_phasezeroSupportSecret1234567890'
                            validation = @{ state = 'passed'; checkedAt = '2026-05-19T00:00:00Z'; message = 'ok' }
                        }
                    }
                }
            }
            targets = (Get-BootstrapSecretsTemplate).targets
        }

        $check = Get-BootstrapGithubCliAuthHealth -SecretsData $fixture
        $json = $check | ConvertTo-Json -Depth 8

        [string]$check.status | Should Be 'warning'
        [string]$check.ghAuthStatus | Should Be 'unauthenticated'
        [bool]$check.tokenAvailable | Should Be $true
        [string]$check.tokenSource | Should Be 'bootstrap-secrets:validated-active'
        [string]$check.recommendedAction | Should Match 'GH_TOKEN'
        $json | Should Not Match 'ghp_phasezeroSupportSecret1234567890'
    }

    It 'returns missing when gh is absent without failing Doctor' {
        Mock Resolve-CommandPath { return $null } -ParameterFilter { $Name -eq 'gh' }

        $check = Get-BootstrapGithubCliAuthHealth -SecretsData @{ providers = @{}; targets = @{} }

        [string]$check.status | Should Be 'missing'
        [string]$check.ghAuthStatus | Should Be 'missing'
        [bool]$check.ghInstalled | Should Be $false
    }

    It 'warns with manual action when gh is unauthenticated and no GitHub token exists' {
        Mock Resolve-CommandPath { return 'C:\Tools\gh.exe' } -ParameterFilter { $Name -eq 'gh' }
        Mock Invoke-BootstrapDoctorCommandProbe {
            return [ordered]@{
                id = 'github-cli-auth'
                status = 'warning'
                severity = 'warning'
                path = 'C:\Tools\gh.exe'
                exitCode = 1
                durationMs = 20
                timedOut = $false
                summary = 'You are not logged into any GitHub hosts.'
            }
        } -ParameterFilter { $CommandName -eq 'gh' -and ((@($CommandArgs) -join ' ') -eq 'auth status') }

        $check = Get-BootstrapGithubCliAuthHealth -SecretsData @{ providers = @{}; targets = @{} }

        [string]$check.status | Should Be 'warning'
        [bool]$check.tokenAvailable | Should Be $false
        [string]$check.recommendedAction | Should Match 'gh auth login'
    }

    It 'reports env-present secrets without exposing token values' {
        $oldOpenAi = $env:OPENAI_API_KEY
        $env:OPENAI_API_KEY = 'sk-phasezeroDoctorSecret1234567890'
        try {
            $doctor = New-BootstrapSecretsDoctorReport -SecretsData @{ providers = @{}; targets = @{} }
            $openai = $doctor.providers | Where-Object { [string]$_.provider -eq 'openai' } | Select-Object -First 1
            $json = $doctor | ConvertTo-Json -Depth 8

            [string]$openai.status | Should Be 'present'
            [string]$openai.source | Should Be 'env'
            [bool]$openai.envPresent | Should Be $true
            $json | Should Not Match 'sk-phasezeroDoctorSecret'
            $json | Should Not Match 'OPENAI_API_KEY'
        } finally {
            if ($null -eq $oldOpenAi) { Remove-Item Env:\OPENAI_API_KEY -ErrorAction SilentlyContinue } else { $env:OPENAI_API_KEY = $oldOpenAi }
        }
    }

    It 'maps OpenRouter 401 validation to rejected without leaking the key' {
        $oldOpenRouter = $env:OPENROUTER_API_KEY
        $env:OPENROUTER_API_KEY = 'sk-or-v1-phasezeroDoctorSecret1234567890'
        Mock Test-BootstrapSecretsProviderCredential {
            return (New-BootstrapSecretValidationState -State 'failed' -CheckedAt '2026-05-26T00:00:00Z' -Message 'HTTP 401 Unauthorized for <redacted>')
        } -ParameterFilter { $ProviderName -eq 'openrouter' }
        try {
            $report = New-BootstrapAiUsagebarDoctorReport -ValidateOpenRouter
            $openrouter = $report.vendors.openrouter
            $json = $report | ConvertTo-Json -Depth 10

            [string]$openrouter.status | Should Be 'rejected'
            [string]$openrouter.lastErrorCode | Should Be '401'
            $json | Should Not Match 'sk-or-v1-phasezeroDoctorSecret'
        } finally {
            if ($null -eq $oldOpenRouter) { Remove-Item Env:\OPENROUTER_API_KEY -ErrorAction SilentlyContinue } else { $env:OPENROUTER_API_KEY = $oldOpenRouter }
        }
    }

    It 'redacts inline ai-usagebar api_key values from diagnostics' {
        $testHome = Join-Path $script:SupportTestRoot 'home'
        $configDir = Join-Path $testHome '.config\ai-usagebar'
        $null = New-Item -Path $configDir -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $configDir 'config.toml') -Encoding utf8 -Value @'
[ui]
primary = "openrouter"

[openrouter]
enabled = true
api_key = "sk-or-v1-inlinePhaseZeroSecret1234567890"
'@
        $oldUserProfile = $env:USERPROFILE
        $env:USERPROFILE = $testHome
        try {
            $report = New-BootstrapAiUsagebarDoctorReport
            $json = $report | ConvertTo-Json -Depth 10

            [bool]$report.configured | Should Be $true
            [string]$report.primaryVendor | Should Be 'openrouter'
            [string]$report.vendors.openrouter.status | Should Be 'present'
            $json | Should Not Match 'sk-or-v1-inlinePhaseZeroSecret'
            $json | Should Match 'inlineApiKeyPresent'
        } finally {
            if ($null -eq $oldUserProfile) { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $oldUserProfile }
        }
    }

    It 'reports AionUI doctor fields without exposing provider env values' {
        $oldOpenAi = $env:OPENAI_API_KEY
        $oldGemini = $env:GEMINI_API_KEY
        if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) { $env:OPENAI_API_KEY = 'phasezero-test-openai-doctor' }
        if ([string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) { $env:GEMINI_API_KEY = 'phasezero-test-gemini-doctor' }
        try {
            $report = Get-BootstrapAionUiDoctorReport
            $json = $report | ConvertTo-Json -Depth 10

            $report.Contains('installed') | Should Be $true
            $report.Contains('version') | Should Be $true
            $report.Contains('exePath') | Should Be $true
            $report.Contains('configPath') | Should Be $true
            $report.Contains('configStatus') | Should Be $true
            $report.Contains('providersConfigured') | Should Be $true
            $report.Contains('providersRejected') | Should Be $true
            [int64]$report['durationMs'] | Should BeGreaterThan -1
            $json | Should Not Match 'phasezero-test-openai-doctor|phasezero-test-gemini-doctor'
            $json | Should Not Match 'OPENAI_API_KEY|GEMINI_API_KEY|sk-|protectedData'
        } finally {
            if ($null -eq $oldOpenAi) { Remove-Item Env:\OPENAI_API_KEY -ErrorAction SilentlyContinue } else { $env:OPENAI_API_KEY = $oldOpenAi }
            if ($null -eq $oldGemini) { Remove-Item Env:\GEMINI_API_KEY -ErrorAction SilentlyContinue } else { $env:GEMINI_API_KEY = $oldGemini }
        }
    }

    It 'reports WSL REGDB_E_CLASSNOTREG as blocked critical without hanging' {
        Mock Resolve-CommandPath { return 'C:\Windows\System32\wsl.exe' } -ParameterFilter { $Name -eq 'wsl.exe' }
        Mock Test-BootstrapAppxPackageInstalled { return $true }
        Mock Get-Service { return [pscustomobject]@{ Name = 'LxssManager'; Status = 'Running' } }
        Mock Test-IsAdmin { return $false }
        Mock Get-BootstrapWslStatusProbe {
            return @{ exitCode = 1; stdout = ''; stderr = 'Wsl/CallMsi/Install/REGDB_E_CLASSNOTREG'; timedOut = $false }
        }

        $report = New-BootstrapWslRepairDoctorReport

        [string]$report.status | Should Be 'blocked'
        [bool]$report.corruptionDetected | Should Be $true
        [string]$report.corruptionKind | Should Be 'REGDB_E_CLASSNOTREG'
        [bool]$report.requiresAdmin | Should Be $true
        [string]$report.recommendedAction | Should Match 'PowerShell.*administrador|elevado|ExecuteRepairPlan'
        [long]$report.durationMs | Should BeGreaterThan -1
        Assert-MockCalled Get-BootstrapWslStatusProbe -Times 1 -Exactly
    }

    It 'adds repair-wsl-registration to RepairPlan with explicit confirmation metadata' {
        $doctor = [ordered]@{
            checks = @()
            auditResults = @()
            wslRepair = [ordered]@{
                status = 'blocked'
                corruptionDetected = $true
                corruptionKind = 'REGDB_E_CLASSNOTREG'
                requiresAdmin = $true
                recommendedAction = 'Run elevated repair plan.'
            }
        }

        $plan = New-BootstrapRepairPlan -DoctorReport $doctor
        $item = $plan.items | Where-Object { [string]$_.id -eq 'repair-wsl-registration' } | Select-Object -First 1

        $item | Should Not Be $null
        [string]$item.component | Should Be 'wsl-core'
        [string]$item.risk | Should Be 'high'
        [bool]$item.requiresAdmin | Should Be $true
        [bool]$item.rollbackAvailable | Should Be $false
        [bool]$item.confirmationRequired | Should Be $true
        [string]$item.reason | Should Match 'REGDB_E_CLASSNOTREG'
    }

    It 'blocks WSL registration repair when current process is not admin' {
        $planPath = Join-Path $script:SupportTestRoot 'wsl-repair-plan.json'
        $resultPath = Join-Path $script:SupportTestRoot 'wsl-repair.result.json'
        [ordered]@{
            schemaVersion = 1
            items = @(
                [ordered]@{
                    id = 'repair-wsl-registration'
                    component = 'wsl-core'
                    risk = 'high'
                    requiresAdmin = $true
                    rollbackAvailable = $false
                    dryRunCommand = '.\bootstrap-tools.ps1 -Component wsl-core -DryRun -NonInteractive'
                    executeCommand = '.\bootstrap-tools.ps1 -Component wsl-core -NonInteractive'
                    reason = 'REGDB_E_CLASSNOTREG'
                    confirmationRequired = $true
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding utf8
        Mock Test-IsAdmin { return $false }

        $script:ResultPath = $resultPath
        $script:LogPath = Join-Path $script:SupportTestRoot 'wsl-repair.log'
        $oldNonInteractive = $script:NonInteractive
        $oldInteractive = $script:Interactive
        try {
            $script:NonInteractive = $false
            $script:Interactive = $true
            $result = Invoke-BootstrapRepairPlanMode -ExecutePath $planPath

            [string]$result.Status | Should Be 'blocked'
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.blockerKind | Should Be 'repair-plan-admin-required'
            [string]$json.howToFix | Should Match 'administrador|elevado'
        } finally {
            $script:NonInteractive = $oldNonInteractive
            $script:Interactive = $oldInteractive
            $script:ResultPath = ''
            $script:LogPath = ''
        }
    }

    It 'writes result json when WSL probe times out during Doctor' {
        $resultPath = Join-Path $script:SupportTestRoot 'doctor-wsl-timeout.result.json'
        Mock New-BootstrapDoctorReport {
            return [ordered]@{
                status = 'warning'
                checks = @()
                auditSummary = [pscustomobject]@{ critical = 0; timedOut = 1 }
                wslRepair = [ordered]@{
                    status = 'blocked'
                    corruptionDetected = $false
                    corruptionKind = 'unknown'
                    requiresAdmin = $false
                    recommendedAction = 'WSL probe timed out; retry later.'
                    durationMs = 1000
                }
            }
        }
        Mock New-BootstrapRepairPlan { return [ordered]@{ schemaVersion = 1; items = @() } }
        Mock Write-Log {}
        $script:ResultPath = $resultPath
        try {
            Invoke-BootstrapDoctorMode

            Test-Path -LiteralPath $resultPath | Should Be $true
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'doctor'
            [string]$json.doctor.wslRepair.status | Should Be 'blocked'
        } finally {
            $script:ResultPath = ''
        }
    }

    It 'keeps public-beta useful without heavy WSL, Docker, AI desktop or gaming stacks' {
        $resolution = Resolve-BootstrapComponents -SelectedProfiles @('public-beta') -SelectedComponents @() -ExcludedComponents @()
        $resolved = @($resolution.ResolvedComponents)

        foreach ($expected in @('git-core','node-core','python-core','dotnet-core','notepadpp','powershell','powertoys','brave','bootstrap-secrets','vscode','vscode-extensions','bootstrap-mcps')) {
            ($resolved -contains $expected) | Should Be $true
        }
        foreach ($forbidden in @('docker','wsl-core','claude-desktop','cursor','steam','steamdeck-tools')) {
            ($resolved -contains $forbidden) | Should Be $false
        }
    }

    It 'writes a structured doctor result with health checks, audit summary and repair plan preview' {
        $resultPath = Join-Path $script:SupportTestRoot 'doctor.result.json'
        $logPath = Join-Path $script:SupportTestRoot 'doctor.log'

        $result = Invoke-SupportBootstrap -CommandArgs @('-Doctor', '-DryRun', '-NonInteractive', '-AuditTimeoutSeconds', '30', '-AuditComponentTimeoutSeconds', '3', '-ResultPath', $resultPath, '-LogPath', $logPath)

        $result.ExitCode | Should Be 0
        Test-Path -LiteralPath $resultPath | Should Be $true
        $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
        [string]$json.mode | Should Be 'doctor'
        $json.doctor | Should Not Be $null
        $json.doctor.checks | Should Not Be $null
        $json.doctor.deck | Should Not Be $null
        (@('healthy','warning','critical','notDetected') -contains [string]$json.doctor.deck.status) | Should Be $true
        $json.doctor.auditSummary | Should Not Be $null
        $json.repairPlan | Should Not Be $null
        @($json.repairPlan.items).Count | Should BeGreaterThan -1
        [string]$json.artifactPaths.logPath | Should Be $logPath
    }

    It 'detects a mocked Steam Deck and surfaces read-only deck checks' {
        function Get-BootstrapDeckCimInstance {
            param([string]$ClassName)
            switch ($ClassName) {
                'Win32_ComputerSystem' { return @([pscustomobject]@{ Manufacturer = 'Valve'; Model = 'Jupiter'; SystemType = 'x64-based PC' }) }
                'Win32_BaseBoard' { return @([pscustomobject]@{ Manufacturer = 'Valve'; Product = 'Jupiter' }) }
                'Win32_BIOS' { return @([pscustomobject]@{ Manufacturer = 'Valve'; SMBIOSBIOSVersion = 'F7A0121' }) }
                'Win32_VideoController' { return @([pscustomobject]@{ Name = 'AMD Custom GPU 0405'; DriverVersion = '31.0.22023.1014' }) }
                'Win32_Battery' { return @([pscustomobject]@{ EstimatedChargeRemaining = 88; BatteryStatus = 2 }) }
                'Win32_DesktopMonitor' { return @([pscustomobject]@{ Name = 'Steam Deck Display'; PNPDeviceID = 'DISPLAY\\VLV0001' }) }
                default { return @() }
            }
        }
        function Invoke-BootstrapDeckCommandProbe {
            param([string]$Label, [string]$FileName, [string[]]$Arguments, [int]$TimeoutMs)
            $null = $FileName
            $null = $Arguments
            $null = $TimeoutMs
            return [ordered]@{ label = $Label; exitCode = 0; timedOut = $false; output = 'Power Scheme GUID: deck-balanced (Balanced)' }
        }
        function Test-BootstrapDeckAnyPath {
            param([string[]]$Paths)
            return (($Paths -join ';') -match 'Steam|Handheld Companion|GlosSI')
        }

        $deck = New-BootstrapSteamDeckDoctorReport

        [string]$deck.status | Should Be 'warning'
        [bool]$deck.isLikelySteamDeck | Should Be $true
        $deck.durationMs | Should Not Be $null
        @($deck.checks).Count | Should BeGreaterThan 3
        (($deck.checks | Where-Object { [string]$_['id'] -eq 'deck-input-conflicts' } | Select-Object -First 1)['status']) | Should Be 'warning'
        (($deck.checks | Where-Object { [string]$_['id'] -eq 'deck-amd-driver' } | Select-Object -First 1)['status']) | Should Be 'healthy'
    }

    It 'returns notDetected for a normal PC without failing Doctor' {
        function Get-BootstrapDeckCimInstance {
            param([string]$ClassName)
            if ($ClassName -eq 'Win32_ComputerSystem') { return @([pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'Precision' }) }
            return @()
        }
        function Invoke-BootstrapDeckCommandProbe {
            param([string]$Label, [string]$FileName, [string[]]$Arguments, [int]$TimeoutMs)
            $null = $FileName
            $null = $Arguments
            $null = $TimeoutMs
            return [ordered]@{ label = $Label; exitCode = $null; timedOut = $false; output = '' }
        }
        function Test-BootstrapDeckAnyPath {
            param([string[]]$Paths)
            $null = $Paths
            return $false
        }

        $deck = New-BootstrapSteamDeckDoctorReport

        [string]$deck.status | Should Be 'notDetected'
        [bool]$deck.isLikelySteamDeck | Should Be $false
        ($deck.checks | Where-Object { [string]$_['id'] -eq 'deck-hardware' } | Select-Object -First 1) | Should Not Be $null
    }

    It 'creates a support bundle with redacted diagnostics and no raw secrets' {
        $resultPath = Join-Path $script:SupportTestRoot 'support.result.json'
        $logPath = Join-Path $script:SupportTestRoot 'support.log'
        $dataRoot = Join-Path $script:SupportTestRoot 'data'
        $env:BOOTSTRAP_DATA_ROOT = $dataRoot
        try {
            $secretPath = Join-Path $dataRoot 'bootstrap-secrets.json'
            Write-BootstrapJsonFile -Path $secretPath -Value @{
                metadata = @{ version = 2 }
                providers = @{
                    openai = @{
                        activeCredential = 'openai-main'
                        rotationOrder = @('openai-main')
                        credentials = @{
                            'openai-main' = @{
                                displayName = 'Main'
                                secretKind = 'apiKey'
                                secret = 'phasezero-support-secret'
                            }
                        }
                    }
                    github = @{
                        activeCredential = 'github-main'
                        rotationOrder = @('github-main')
                        credentials = @{
                            'github-main' = @{
                                displayName = 'Main GitHub'
                                secretKind = 'token'
                                secret = 'ghp_phasezeroSupportSecret1234567890'
                                validation = @{ state = 'passed'; checkedAt = '2026-05-19T00:00:00Z'; message = 'ok' }
                            }
                        }
                    }
                }
                targets = @{}
            }

            $result = Invoke-SupportBootstrap -CommandArgs @('-SupportBundle', '-DryRun', '-NonInteractive', '-AuditTimeoutSeconds', '30', '-AuditComponentTimeoutSeconds', '3', '-ResultPath', $resultPath, '-LogPath', $logPath)

            $result.ExitCode | Should Be 0
            $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$json.mode | Should Be 'support-bundle'
            [string]$json.supportBundle.path | Should Match '\.zip$'
            Test-Path -LiteralPath ([string]$json.supportBundle.path) | Should Be $true

            $extractRoot = Join-Path $script:SupportTestRoot 'bundle'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory([string]$json.supportBundle.path, $extractRoot)
            $bundleFiles = @(Get-ChildItem -Path $extractRoot -Recurse -File)
            $bundleNames = @($bundleFiles | ForEach-Object { $_.Name })
            $allText = (Get-ChildItem -Path $extractRoot -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue }) -join [Environment]::NewLine

            $allText | Should Match 'doctor'
            ($bundleNames -contains 'deck-doctor.json') | Should Be $true
            ($bundleNames -contains 'secrets-doctor.json') | Should Be $true
            ($bundleNames -contains 'ai-usagebar.json') | Should Be $true
            ($bundleNames -contains 'aionui.json') | Should Be $true
            ($bundleNames -contains 'wsl-repair.json') | Should Be $true
            ($bundleNames -contains 'deck-power.json') | Should Be $true
            ($bundleNames -contains 'deck-display.json') | Should Be $true
            ($bundleNames -contains 'deck-libraries.json') | Should Be $true
            ($bundleNames -contains 'github-auth.json') | Should Be $true
            (@($bundleNames | Where-Object { $_ -match 'batteryreport\.html|energy-report\.html|\.env' }).Count) | Should Be 0
            $allText | Should Not Match 'phasezero-support-secret'
            $allText | Should Not Match 'ghp_phasezeroSupportSecret1234567890'
            $allText | Should Not Match 'GH_TOKEN'
            $allText | Should Not Match 'ghp_'
            $allText | Should Not Match 'sk-'
            $allText | Should Not Match 'sk-or-'
            $allText | Should Not Match 'sk-ant-'
            $allText | Should Not Match 'github_pat_'
            $allText | Should Not Match 'protectedData'
            $allText | Should Not Match 'OPENAI_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|OPENROUTER_API_KEY|DEEPSEEK_API_KEY|XAI_API_KEY|DASHSCOPE_API_KEY|QWEN_API_KEY|ZAI_API_KEY'
            $allText | Should Not Match ([regex]::Escape($env:USERPROFILE))
            $allText | Should Not Match '203\.0\.113\.10'
            @(Get-ChildItem -Path $extractRoot -Recurse -File | Where-Object { $_.Name -match 'bootstrap-secrets|\.env' }).Count | Should Be 0
        } finally {
            Remove-Item Env:\BOOTSTRAP_DATA_ROOT -ErrorAction SilentlyContinue
        }
    }

    It 'blocks repair plan execution in noninteractive mode without explicit manual confirmation' {
        $planPath = Join-Path $script:SupportTestRoot 'repair-plan.json'
        $resultPath = Join-Path $script:SupportTestRoot 'execute-repair.result.json'
        [ordered]@{
            schemaVersion = 1
            items = @(
                [ordered]@{
                    id = 'repair-test'
                    component = 'winget'
                    risk = 'low'
                    requiresAdmin = $false
                    rollbackAvailable = $false
                    dryRunCommand = '.\bootstrap-tools.ps1 -Doctor -DryRun'
                    executeCommand = '.\bootstrap-tools.ps1 -Doctor'
                    reason = 'test'
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding utf8

        $result = Invoke-SupportBootstrap -CommandArgs @('-ExecuteRepairPlan', $planPath, '-NonInteractive', '-ResultPath', $resultPath)

        ($result.ExitCode -ne 0) | Should Be $true
        $json = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
        [string]$json.status | Should Be 'blocked'
        [string]$json.mode | Should Be 'repair-plan'
        [string]$json.blockerKind | Should Be 'repair-plan-confirmation-required'
    }

    It 'adds duration fields to RepairPlan and SupportBundle payloads' {
        $doctor = [ordered]@{
            checks = @()
            auditResults = @()
            wslRepair = [ordered]@{
                status = 'healthy'
                corruptionDetected = $false
                corruptionKind = 'unknown'
                recommendedAction = 'No action required.'
            }
            deck = [ordered]@{ power = [ordered]@{}; display = [ordered]@{}; libraries = @() }
            githubCliAuth = [ordered]@{ status = 'missing' }
            secrets = [ordered]@{ providers = @() }
            aiUsagebar = [ordered]@{ vendors = [ordered]@{} }
        }
        $plan = New-BootstrapRepairPlan -DoctorReport $doctor
        [long]$plan['durationMs'] | Should BeGreaterThan -1

        $bundlePath = Join-Path $script:SupportTestRoot 'bundle.zip'
        $payload = [ordered]@{ status = 'success'; doctor = $doctor; repairPlan = $plan }
        $bundle = New-BootstrapSupportBundle -DoctorReport $doctor -RepairPlan $plan -ResultPayload $payload -DestinationPath $bundlePath
        [long]$bundle['durationMs'] | Should BeGreaterThan -1
        Test-Path -LiteralPath $bundlePath | Should Be $true
    }
}
