$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Safe container hosting and AI edge automation packs' {
    It 'declares safe automation AppTuning categories and items with aliases' {
        $catalog = Get-BootstrapAppTuningCatalog
        $categoryIds = @($catalog.categories | ForEach-Object { [string]$_.id })
        $byId = @{}
        foreach ($item in @($catalog.items)) { $byId[[string]$item.id] = $item }

        foreach ($expected in @('container-hosting','ai-edge-safe')) {
            ($categoryIds -contains $expected) | Should Be $true
        }

        foreach ($id in @(
            'reverse-proxy-traefik-pack',
            'compose-app-template',
            'docker-hosting-doctor',
            'n8n-hosting-workflow-template',
            'ai-edge-openai-compatible-template',
            'ai-provider-gateway-config',
            'ai-gateway-doctor'
        )) {
            $byId.ContainsKey($id) | Should Be $true
            [string]$byId[$id].defaultMode | Should Be 'opt-in'
            [string]$byId[$id].riskTier | Should Match '^(conservative|manual)$'
            [string]$byId[$id].rollbackScope | Should Not Be ''
            @($byId[$id].safetyNotes).Count | Should BeGreaterThan 0
            @($byId[$id].aliases).Count | Should BeGreaterThan 0
        }

        (@($byId['reverse-proxy-traefik-pack'].aliases) -contains 'traefik') | Should Be $true
        (@($byId['reverse-proxy-traefik-pack'].aliases) -contains 'reverse-proxy') | Should Be $true
        (@($byId['compose-app-template'].aliases) -contains 'compose-template') | Should Be $true
        (@($byId['docker-hosting-doctor'].aliases) -contains 'docker-doctor') | Should Be $true
        (@($byId['ai-edge-openai-compatible-template'].aliases) -contains 'ai-edge') | Should Be $true
        (@($byId['ai-provider-gateway-config'].aliases) -contains 'byok-gateway') | Should Be $true
        (@($byId['ai-provider-gateway-config'].targetApps) -contains 'opencode') | Should Be $true
        (@($byId['ai-provider-gateway-config'].targetApps) -contains 'hermes') | Should Be $true
    }

    It 'generates Traefik and app compose templates without exposing app host ports' {
        $workspace = Join-Path $TestDrive 'safe-hosting'
        $result = Ensure-BootstrapContainerHostingPack -WorkspaceRoot $workspace

        [string]$result.status | Should Match '^(applied|configured)$'
        $traefikPath = Join-Path $workspace '.phasezero\container-hosting\traefik\docker-compose.yml'
        $appPath = Join-Path $workspace '.phasezero\container-hosting\templates\compose-app.yml'
        $doctorPath = Join-Path $workspace '.phasezero\container-hosting\docker-hosting-doctor.ps1'

        Test-Path -LiteralPath $traefikPath | Should Be $true
        Test-Path -LiteralPath $appPath | Should Be $true
        Test-Path -LiteralPath $doctorPath | Should Be $true

        $traefik = Get-Content -LiteralPath $traefikPath -Raw
        $app = Get-Content -LiteralPath $appPath -Raw

        $traefik | Should Match 'traefik:v'
        $traefik | Should Match 'proxy-net'
        $traefik | Should Match '80:80'
        $traefik | Should Match '443:443'
        $app | Should Match 'traefik.enable=true'
        $app | Should Match 'proxy-net'
        $app | Should Match 'external: true'
        $app | Should Match 'healthcheck:'
        $app | Should Match 'max-size'
        $app | Should Not Match '(?m)^\s*ports:\s*$'
    }

    It 'returns read-only Docker hosting doctor diagnostics when docker is absent' {
        Mock Resolve-CommandPath { return '' } -ParameterFilter { $Name -eq 'docker' -or $Name -eq 'docker.exe' }

        $report = Get-BootstrapDockerHostingDoctorReport
        $json = $report | ConvertTo-Json -Depth 8

        [string]$report.status | Should Be 'blocked'
        $json | Should Match 'docker-command'
        $json | Should Match 'proxy-net'
    }

    It 'generates a BYOK-only OpenAI-compatible edge template and documents blocked patterns' {
        $workspace = Join-Path $TestDrive 'safe-ai-edge'
        $result = Ensure-BootstrapAiEdgeSafeTemplate -WorkspaceRoot $workspace

        [string]$result.status | Should Match '^(applied|configured)$'
        $serverPath = Join-Path $workspace '.phasezero\ai-edge-safe\server.js'
        $packagePath = Join-Path $workspace '.phasezero\ai-edge-safe\package.json'
        $policyPath = Join-Path $workspace '.phasezero\ai-edge-safe\SECURITY.md'

        Test-Path -LiteralPath $serverPath | Should Be $true
        Test-Path -LiteralPath $packagePath | Should Be $true
        Test-Path -LiteralPath $policyPath | Should Be $true

        $server = Get-Content -LiteralPath $serverPath -Raw
        $policy = Get-Content -LiteralPath $policyPath -Raw

        $server | Should Match '/v1/models'
        $server | Should Match '/v1/chat/completions'
        $server | Should Match 'text/event-stream'
        $server | Should Match 'AI_PROVIDER_BASE_URL'
        $server | Should Not Match 'playwright|puppeteer|cookie|captcha|cloudflare|proxyRotation'
        $policy | Should Match 'No token scraping'
        $policy | Should Match 'No WAF'
        $policy | Should Match 'BYOK'
    }

    It 'redacts AI gateway doctor secrets and never reports raw keys' {
        $report = Get-BootstrapAiGatewayDoctorReport -BaseUrl '' -ApiKey 'sk-test-phasezero-secret'
        $json = $report | ConvertTo-Json -Depth 8

        [string]$report.status | Should Be 'blocked'
        $json | Should Not Match 'sk-test-phasezero-secret'
        $json | Should Not Match 'OPENAI_API_KEY'
        $json | Should Match 'secretPresent'
    }

    It 'applies safe automation items through AppTuning without unsafe mutation' {
        $workspace = Join-Path $TestDrive 'apptuning-safe'
        $state = @{ CloneBaseDir = $workspace }

        $container = Invoke-BootstrapAppTuningItem -State $state -Item ([ordered]@{
            id = 'reverse-proxy-traefik-pack'
            category = 'container-hosting'
            installed = $true
        })
        $aiEdge = Invoke-BootstrapAppTuningItem -State $state -Item ([ordered]@{
            id = 'ai-edge-openai-compatible-template'
            category = 'ai-edge-safe'
            installed = $true
        })

        [string]$container.status | Should Match '^(applied|configured)$'
        [string]$aiEdge.status | Should Match '^(applied|configured)$'
        Test-Path -LiteralPath (Join-Path $workspace '.phasezero\container-hosting\traefik\docker-compose.yml') | Should Be $true
        Test-Path -LiteralPath (Join-Path $workspace '.phasezero\ai-edge-safe\server.js') | Should Be $true
    }
}
