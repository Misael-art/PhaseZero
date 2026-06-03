$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsScriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

. $toolsScriptPath -BootstrapUiLibraryMode
Reset-BootstrapFileCmdlets
$script:RealAiProxyCatalogForTests = Get-BootstrapAiProxyCatalog

function New-AiProxySuiteTestRoot {
    $root = Join-Path $env:TEMP ("PhaseZero AI Proxy Suite {0}" -f ([Guid]::NewGuid().ToString('N')))
    $null = New-Item -Path $root -ItemType Directory -Force
    return $root
}

Describe 'AI proxy suite support' {
    BeforeEach {
        $script:AiProxySuiteRoot = New-AiProxySuiteTestRoot
    }

    AfterEach {
        Remove-Item -LiteralPath $script:AiProxySuiteRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name AiProxySuiteRoot -ErrorAction SilentlyContinue
    }

    It 'declares pedrofariasx proxies and Docker Native Manager as default AI managed tools' {
        $catalog = Get-BootstrapAiToolCatalog
        $components = Get-BootstrapComponentCatalog
        $profiles = Get-BootstrapProfileCatalog
        $contract = Get-BootstrapUiContract

        $catalog.Contains('ai-proxy-suite') | Should Be $true
        foreach ($toolName in @('kimiproxy','qwenproxy','deepsproxy','mimo-ai-proxy','antigravity-openai-adapter','dockernativemanager')) {
            $catalog.Contains($toolName) | Should Be $true
            [string]$catalog[$toolName].GitHubRepo | Should Match '^pedrofariasx/'
            [string]$catalog[$toolName].RepoUrl | Should Match '^https://github.com/pedrofariasx/'
            [string]$catalog[$toolName].InstallSupport | Should Match '^git-'
            $components.Contains($toolName) | Should Be $true
            (@($profiles['legacy'].Items) -contains $toolName) | Should Be $true
            (@($profiles['ai'].Items) -contains $toolName) | Should Be $true
            (@($profiles['safe-base'].Items) -contains $toolName) | Should Be $false
            (@($profiles['public-beta'].Items) -contains $toolName) | Should Be $false
        }

        [bool]$contract.capabilities.aiProxySuite | Should Be $true
        [string]$catalog['kimiproxy'].DefaultModel | Should Be 'k2d6-thinking'
        [bool]$catalog['kimiproxy'].PreferredDefault | Should Be $true

        $ports = @('kimiproxy','qwenproxy','deepsproxy','mimo-ai-proxy','antigravity-openai-adapter' | ForEach-Object { [int]$catalog[$_].Port })
        @($ports | Select-Object -Unique).Count | Should Be $ports.Count
    }

    It 'plans KimiProxy install with unique port, Playwright and Kimi as preferred model' {
        $result = Invoke-BootstrapAiToolAction -ToolName 'kimi-proxy' -Action 'install' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $repoRoot -DryRun -Yes

        [string]$result.tool | Should Be 'kimiproxy'
        [string]$result.status | Should Be 'planned'
        [string]$result.repoUrl | Should Be 'https://github.com/pedrofariasx/kimiproxy.git'
        [int]$result.port | Should Be 3010
        [string]$result.baseUrl | Should Be 'http://127.0.0.1:3010/v1'
        [string]$result.defaultModel | Should Be 'k2d6-thinking'
        [bool]$result.playwright | Should Be $true
        [string]$result.message | Should Match 'npm install'
        [string]$result.message | Should Match 'playwright install chromium'
    }

    It 'writes proxy env and manifest without exposing env secret values in result' {
        $oldQwenEmail = $env:QWEN_EMAIL
        $oldQwenPassword = $env:QWEN_PASSWORD
        $env:QWEN_EMAIL = 'phasezero-qwen@example.test'
        $env:QWEN_PASSWORD = 'phasezero-qwen-password-secret'
        try {
            $result = Invoke-BootstrapAiToolAction -ToolName 'qwenproxy' -Action 'configure' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $repoRoot -Yes
            $json = $result | ConvertTo-Json -Depth 12
            $envPath = [string]$result.envPath
            $envText = Get-Content -LiteralPath $envPath -Raw -Encoding UTF8

            [string]$result.status | Should Be 'configured'
            Test-Path -LiteralPath $envPath | Should Be $true
            $envText | Should Match 'PORT=3011'
            $envText | Should Match 'QWEN_EMAIL=phasezero-qwen@example.test'
            $envText | Should Match 'QWEN_PASSWORD=phasezero-qwen-password-secret'
        $json | Should Not Match 'phasezero-qwen@example.test|phasezero-qwen-password-secret'
        $json | Should Not Match 'QWEN_PASSWORD|QWEN_EMAIL'
        } finally {
            if ($null -eq $oldQwenEmail) { Remove-Item Env:\QWEN_EMAIL -ErrorAction SilentlyContinue } else { $env:QWEN_EMAIL = $oldQwenEmail }
            if ($null -eq $oldQwenPassword) { Remove-Item Env:\QWEN_PASSWORD -ErrorAction SilentlyContinue } else { $env:QWEN_PASSWORD = $oldQwenPassword }
        }
    }

    It 'configures KimiProxy as default provider for IDE targets' {
        $oldUserProfile = $env:USERPROFILE
        $oldAppData = $env:APPDATA
        $oldLocalAppData = $env:LOCALAPPDATA
        $oldDataRoot = $env:BOOTSTRAP_DATA_ROOT
        $projectRoot = Join-Path $script:AiProxySuiteRoot 'Project'
        $env:USERPROFILE = Join-Path $script:AiProxySuiteRoot 'User'
        $env:APPDATA = Join-Path $script:AiProxySuiteRoot 'User\AppData\Roaming'
        $env:LOCALAPPDATA = Join-Path $script:AiProxySuiteRoot 'User\AppData\Local'
        $env:BOOTSTRAP_DATA_ROOT = Join-Path $script:AiProxySuiteRoot 'Data'
        New-Item -Path $projectRoot,$env:USERPROFILE,$env:APPDATA,$env:LOCALAPPDATA,$env:BOOTSTRAP_DATA_ROOT -ItemType Directory -Force | Out-Null
        try {
            $kimi = Invoke-BootstrapAiToolAction -ToolName 'kimiproxy' -Action 'configure' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $projectRoot -Yes
            $envMap = Read-BootstrapDotEnvFile -Path ([string]$kimi.envPath)
            $localKey = [string]$envMap['API_KEY']

            $result = Invoke-BootstrapAiToolAction -ToolName 'ai-proxy-suite' -Action 'configure' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $projectRoot -Yes
            $json = $result | ConvertTo-Json -Depth 20

            [string]$result.status | Should Be 'configured'
            [string]$result.defaultProvider | Should Be 'kimiproxy'
            [string]$result.defaultBaseUrl | Should Be 'http://127.0.0.1:3010/v1'
            [string]$result.defaultModel | Should Be 'k2d6-thinking'

            $continueConfig = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.continue\config.yaml') -Raw -Encoding UTF8
            $continueEnv = Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.continue\.env') -Raw -Encoding UTF8
            $continueConfig | Should Match 'PhaseZero KimiProxy'
            $continueConfig | Should Match 'model: k2d6-thinking'
            $continueConfig | Should Match 'apiBase: http://127.0.0.1:3010/v1'
            $continueConfig | Should Match '\$\{\{ secrets.KIMIPROXY_API_KEY \}\}'
            $continueEnv | Should Match 'KIMIPROXY_API_KEY='
            $continueEnv | Should Match 'OPENAI_MODEL="?k2d6-thinking"?'

            $openCode = Read-BootstrapJsonFile -Path (Join-Path $env:USERPROFILE '.config\opencode\opencode.json')
            [string]$openCode.model | Should Be 'phasezero-kimi/k2d6-thinking'
            [string]$openCode.provider['phasezero-kimi'].options.baseURL | Should Be 'http://127.0.0.1:3010/v1'
            [string]$openCode.provider['phasezero-kimi'].options.apiKey | Should Be $localKey

            $hermes = Read-BootstrapJsonFile -Path (Join-Path $projectRoot '.hermes\opencloud.json')
            [string]$hermes.env.OPENAI_BASE_URL | Should Be 'http://127.0.0.1:3010/v1'
            [string]$hermes.env.OPENAI_MODEL | Should Be 'k2d6-thinking'

            $json | Should Not Match ([regex]::Escape($localKey))
        } finally {
            if ($null -eq $oldUserProfile) { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $oldUserProfile }
            if ($null -eq $oldAppData) { Remove-Item Env:\APPDATA -ErrorAction SilentlyContinue } else { $env:APPDATA = $oldAppData }
            if ($null -eq $oldLocalAppData) { Remove-Item Env:\LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $oldLocalAppData }
            if ($null -eq $oldDataRoot) { Remove-Item Env:\BOOTSTRAP_DATA_ROOT -ErrorAction SilentlyContinue } else { $env:BOOTSTRAP_DATA_ROOT = $oldDataRoot }
        }
    }

    It 'adds redacted proxy diagnostics to Doctor and SupportBundle' {
        $report = New-BootstrapAiProxySuiteDoctorReport -InstallRoot $script:AiProxySuiteRoot
        $doctor = [ordered]@{
            aiProxies = $report
            checks = @()
            auditResults = @()
            auditSummary = [ordered]@{ critical = 0; timedOut = 0 }
        }
        $repair = [ordered]@{ items = @() }
        $bundlePath = Join-Path $script:AiProxySuiteRoot 'support.zip'
        $bundle = New-BootstrapSupportBundle -DoctorReport $doctor -RepairPlan $repair -ResultPayload ([ordered]@{ status = 'success'; doctor = $doctor }) -DestinationPath $bundlePath

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $extractRoot = Join-Path $script:AiProxySuiteRoot 'extract'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($bundlePath, $extractRoot)
        $names = @(Get-ChildItem -Path $extractRoot -Recurse -File | ForEach-Object { $_.FullName.Substring($extractRoot.Length + 1) })
        $allText = @(Get-ChildItem -Path $extractRoot -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join [Environment]::NewLine

        (@($bundle.included) -contains 'ai-proxy-suite.json') | Should Be $true
        (@($names) -contains 'ai-proxy-suite.json') | Should Be $true
        $allText | Should Not Match 'API_KEY|QWEN_PASSWORD|SERVICE_TOKEN|USER_ID|XIAOMI_CHATBOT_PH|sk-'
    }

    It 'does not mark a proxy configured when files exist but API is not listening' {
        $catalog = $script:RealAiProxyCatalogForTests
        $entry = ConvertTo-BootstrapHashtable -InputObject $catalog['kimiproxy']
        $entry['Port'] = 65534
        $entry['BaseUrl'] = 'http://127.0.0.1:65534/v1'
        $script:AiProxyCatalogOverride = [ordered]@{ kimiproxy = $entry }
        try {
            Mock Get-BootstrapAiProxyCatalog { return $script:AiProxyCatalogOverride }
            $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot
            New-Item -Path (Join-Path $sourceRoot '.git') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $sourceRoot 'node_modules') -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=65534','API_KEY=redacted-test') -Encoding UTF8

            $report = Get-BootstrapAiProxyToolDoctorReport -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot

            [bool]$report.filesConfigured | Should Be $true
            [bool]$report.runtimeReady | Should Be $true
            [bool]$report.listening | Should Be $false
            [string]$report.modelsStatus | Should Be 'unreachable'
            [string]$report.status | Should Be 'start-required'
            [bool]$report.configured | Should Be $false
        } finally {
            $script:AiProxyCatalogOverride = $script:RealAiProxyCatalogForTests
        }
    }

    It 'does not mark suite ready when providers are installed but stopped' {
        $catalog = $script:RealAiProxyCatalogForTests
        $entry = ConvertTo-BootstrapHashtable -InputObject $catalog['kimiproxy']
        $entry['Port'] = 65534
        $entry['BaseUrl'] = 'http://127.0.0.1:65534/v1'
        $script:AiProxyCatalogOverride = [ordered]@{ kimiproxy = $entry }
        try {
            Mock Get-BootstrapAiProxyCatalog { return $script:AiProxyCatalogOverride }
            $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'kimiproxy' -InstallRoot $script:AiProxySuiteRoot
            New-Item -Path (Join-Path $sourceRoot '.git') -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $sourceRoot 'node_modules') -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=65534','API_KEY=redacted-test') -Encoding UTF8

            $suite = New-BootstrapAiProxySuiteDoctorReport -InstallRoot $script:AiProxySuiteRoot

            [string]$suite.status | Should Be 'start-required'
            [int]$suite.configuredProviders | Should Be 0
            [int]$suite.runtimeReadyProviders | Should Be 1
            [int]$suite.startRequiredProviders | Should Be 1
        } finally {
            $script:AiProxyCatalogOverride = $script:RealAiProxyCatalogForTests
        }
    }

    It 'marks a listening proxy with unhealthy /v1/models as unhealthy instead of start-required' {
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'antigravity-openai-adapter' -InstallRoot $script:AiProxySuiteRoot
        New-Item -Path (Join-Path $sourceRoot '.git'),(Join-Path $sourceRoot 'node_modules') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=8081','API_KEY=redacted-test') -Encoding UTF8
        Mock Get-BootstrapAiProxyRuntimeProbe {
            return [ordered]@{
                listening = $true
                pid = @(1234)
                processName = @('node')
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'error'
                modelsStatusCode = 500
                healthUrl = 'http://127.0.0.1:8081/health'
                modelsUrl = 'http://127.0.0.1:8081/v1/models'
                runtimeAvailable = $false
                durationMs = 40
            }
        }

        $report = Get-BootstrapAiProxyToolDoctorReport -ToolName 'antigravity-openai-adapter' -InstallRoot $script:AiProxySuiteRoot

        [string]$report.status | Should Be 'unhealthy'
        [bool]$report.listening | Should Be $true
        [string]$report.modelsStatus | Should Be 'error'
        [bool]$report.configured | Should Be $false
    }

    It 'marks suite degraded when one HTTP proxy is unhealthy even if a desktop tool is configured' {
        $catalog = $script:RealAiProxyCatalogForTests
        $script:AiProxyCatalogOverride = [ordered]@{
            kimiproxy = $catalog['kimiproxy']
            'antigravity-openai-adapter' = $catalog['antigravity-openai-adapter']
            dockernativemanager = $catalog['dockernativemanager']
        }
        try {
            Mock Get-BootstrapAiProxyCatalog { return $script:AiProxyCatalogOverride }
            Mock Get-BootstrapAiProxyToolDoctorReport {
                if ($ToolName -eq 'antigravity-openai-adapter') {
                    return [ordered]@{ id = 'antigravity-openai-adapter'; status = 'unhealthy'; configured = $false; runtimeReady = $true; port = 8081 }
                }
                if ($ToolName -eq 'dockernativemanager') {
                    return [ordered]@{ id = 'dockernativemanager'; status = 'configured'; configured = $true; runtimeReady = $true; port = 0 }
                }
                return [ordered]@{ id = 'kimiproxy'; status = 'configured'; configured = $true; runtimeReady = $true; port = 3010 }
            }

            $suite = New-BootstrapAiProxySuiteDoctorReport -InstallRoot $script:AiProxySuiteRoot

            [string]$suite.status | Should Be 'degraded'
            [int]$suite.configuredProviders | Should Be 1
            [int]$suite.unhealthyProviders | Should Be 1
        } finally {
            $script:AiProxyCatalogOverride = $script:RealAiProxyCatalogForTests
        }
    }

    It 'plans a start action for ai-proxy-suite without starting processes in dry-run' {
        $result = Invoke-BootstrapAiToolAction -ToolName 'ai-proxy-suite' -Action 'start' -InstallRoot $script:AiProxySuiteRoot -ProjectRoot $repoRoot -DryRun -Yes

        [string]$result.status | Should Be 'planned'
        [string]$result.action | Should Be 'start'
        @($result.startResults).Count | Should BeGreaterThan 0
        [string]$result.message | Should Match 'Start'
    }

    It 'starts a Go proxy executable without requiring an ArgumentList' {
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'mimo-ai-proxy' -InstallRoot $script:AiProxySuiteRoot
        $binDir = Join-Path $sourceRoot 'bin'
        New-Item -Path (Join-Path $sourceRoot '.git'),$binDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=3013','API_KEY=redacted-test') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $binDir 'mimo-ai-proxy.exe') -Value 'test-binary-placeholder' -Encoding ASCII

        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $false
                listening = $false
                pid = @()
                healthStatus = 'unreachable'
                healthStatusCode = 0
                modelsStatus = 'unreachable'
                modelsStatusCode = 0
                modelsUrl = 'http://127.0.0.1:3013/v1/models'
            }
        }
        Mock Start-Process { return [pscustomobject]@{ Id = 4242 } }
        Mock Wait-BootstrapAiProxyRuntime {
            return [ordered]@{
                listening = $true
                pid = @(4242)
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'ok'
                modelsStatusCode = 200
                modelsUrl = 'http://127.0.0.1:3013/v1/models'
                runtimeAvailable = $true
                waitDurationMs = 25
            }
        }

        $result = Start-BootstrapAiProxyTool -ToolName 'mimo-ai-proxy' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'started'
        [int]$result.pid | Should Be 4242
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
        Assert-MockCalled Wait-BootstrapAiProxyRuntime -Times 1 -Exactly -Scope It
    }

    It 'falls back to go run when the compiled Go proxy exe is blocked by policy' {
        $sourceRoot = Get-BootstrapAiProxySourceRoot -ToolName 'mimo-ai-proxy' -InstallRoot $script:AiProxySuiteRoot
        $binDir = Join-Path $sourceRoot 'bin'
        New-Item -Path (Join-Path $sourceRoot '.git'),$binDir -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot '.env') -Value @('PORT=3013','API_KEY=redacted-test') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $binDir 'mimo-ai-proxy.exe') -Value 'test-binary-placeholder' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $sourceRoot 'main.go') -Value 'package main' -Encoding ASCII

        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $false
                listening = $false
                pid = @()
                healthStatus = 'unreachable'
                healthStatusCode = 0
                modelsStatus = 'unreachable'
                modelsStatusCode = 0
                modelsUrl = 'http://127.0.0.1:3013/v1/models'
            }
        }
        Mock Resolve-CommandPath { return 'C:\Tools\go.exe' } -ParameterFilter { $Name -eq 'go' }
        Mock Start-Process {
            if ([string]$FilePath -match 'mimo-ai-proxy\.exe$') { throw 'App Control blocked exe' }
            return [pscustomobject]@{ Id = 5252 }
        }
        Mock Wait-BootstrapAiProxyRuntime {
            return [ordered]@{
                listening = $true
                pid = @(5252)
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'ok'
                modelsStatusCode = 200
                modelsUrl = 'http://127.0.0.1:3013/v1/models'
                runtimeAvailable = $true
                waitDurationMs = 25
            }
        }

        $result = Start-BootstrapAiProxyTool -ToolName 'mimo-ai-proxy' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'started'
        [int]$result.pid | Should Be 5252
        Assert-MockCalled Start-Process -Times 2 -Exactly -Scope It
        Assert-MockCalled Resolve-CommandPath -ParameterFilter { $Name -eq 'go' } -Times 1 -Scope It
    }

    It 'does not start a duplicate process when a proxy is listening but /v1/models is unhealthy' {
        Mock Get-BootstrapAiProxyToolDoctorReport {
            return [ordered]@{
                installed = $true
                filesConfigured = $true
                runtimeReady = $true
                runtimeAvailable = $false
                listening = $true
                pid = @(1234)
                healthStatus = 'ok'
                healthStatusCode = 200
                modelsStatus = 'error'
                modelsStatusCode = 500
                modelsUrl = 'http://127.0.0.1:8081/v1/models'
            }
        }
        Mock Start-Process { throw 'should not start duplicate listener' }

        $result = Start-BootstrapAiProxyTool -ToolName 'antigravity-openai-adapter' -InstallRoot $script:AiProxySuiteRoot -TimeoutMs 1000

        [string]$result.status | Should Be 'error'
        [string]$result.message | Should Match 'ouvindo'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
}
