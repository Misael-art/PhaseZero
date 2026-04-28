$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Bootstrap Notepad++ defaults' {
    It 'returns curated x64 plugin set without unsupported defaults' {
        $plugins = @(Get-BootstrapNotepadPlusPlusDesiredPlugins -Architecture 'x64' -UseFallbackOnly)
        $names = @($plugins | ForEach-Object { [string]$_.displayName })

        foreach ($expected in @('ComparePlus','AutoSave','CollectionInterface','Code Alignment','DSpellCheck','HEX-Editor','JSON Tools','JSON Viewer','JSTool','NppFTP','NppOpenAI','Snippets','XML Tools')) {
            ($names -contains $expected) | Should Be $true
        }

        ($names -contains 'MultiClipboard') | Should Be $false
    }

    It 'marks built-in and unstable extras as deferred on x64' {
        $deferred = @(Get-BootstrapNotepadPlusPlusDeferredCapabilities -Architecture 'x64')
        $ids = @($deferred | ForEach-Object { [string]$_.id })

        ($ids -contains 'function-list') | Should Be $true
        ($ids -contains 'multiclipboard') | Should Be $true
        ($ids -contains 'lsp-client') | Should Be $true

        (($deferred | Where-Object { $_.id -eq 'function-list' } | Select-Object -First 1).reason) | Should Match 'built-in'
        (($deferred | Where-Object { $_.id -eq 'multiclipboard' } | Select-Object -First 1).reason) | Should Match 'x64'
        (($deferred | Where-Object { $_.id -eq 'lsp-client' } | Select-Object -First 1).reason) | Should Match 'alpha|manual'
    }

    It 'defines curated syntax assets and plugin folders' {
        $desired = Get-BootstrapNotepadPlusPlusDesiredState -Architecture 'x64'

        foreach ($expectedPluginFolder in @('ComparePlus','AutoSave','CollectionInterface','CodeAlignmentNpp','DSpellCheck','HexEditor','JsonTools','NPPJSONViewer','JSMinNPP','NppFTP','NppOpenAI','NppSnippets','XMLTools')) {
            (@($desired.pluginFolders) -contains $expectedPluginFolder) | Should Be $true
        }

        foreach ($expectedPath in @(
            'userDefineLangs\AutoHotKey_V2.udl.xml',
            'userDefineLangs\TOML_byTimendum.xml',
            'userDefineLangs\bootstrap-dotenv.udl.xml',
            'userDefineLangs\bootstrap-dockerignore.udl.xml',
            'userDefineLangs\bootstrap-m68k.udl.xml',
            'userDefineLangs\bootstrap-mame-config.udl.xml',
            'userDefineLangs\bootstrap-retrofe-conf.udl.xml',
            'userDefineLangs\bootstrap-sgdk-resource.udl.xml',
            'autoCompletion\AutoHotkey V2.xml',
            'autoCompletion\TOML.xml',
            'plugins\Config\NppOpenAI.ini'
        )) {
            (@($desired.requiredRelativePaths) -contains $expectedPath) | Should Be $true
        }
    }

    It 'recognizes applied marker only when curated payload exists' {
        $root = Join-Path $env:TEMP ('bootstrap-npp-test-' + [guid]::NewGuid().ToString('N'))
        $pluginsRoot = Join-Path $root 'plugins'
        $configRoot = Join-Path $root 'config'
        $pluginConfigRoot = Join-Path $configRoot 'plugins\Config'
        $desired = Get-BootstrapNotepadPlusPlusDesiredState -Architecture 'x64'
        $installInfo = [ordered]@{
            Installed = $true
            Architecture = 'x64'
            InstallRoot = $root
            PluginsRoot = $pluginsRoot
            ConfigRoot = $configRoot
            PluginConfigRoot = $pluginConfigRoot
        }

        try {
            foreach ($folder in @($desired.pluginFolders)) {
                $target = Join-Path $pluginsRoot $folder
                $null = New-Item -Path $target -ItemType Directory -Force
                $dllPath = Join-Path $target ($folder + '.dll')
                Microsoft.PowerShell.Management\Set-Content -Path $dllPath -Value 'stub' -Encoding ascii
            }

            foreach ($relativePath in @($desired.requiredRelativePaths)) {
                $targetPath = Join-Path $configRoot $relativePath
                $parent = Split-Path -Parent $targetPath
                if (-not [string]::IsNullOrWhiteSpace($parent)) {
                    $null = New-Item -Path $parent -ItemType Directory -Force
                }
                Microsoft.PowerShell.Management\Set-Content -Path $targetPath -Value 'stub' -Encoding ascii
            }

            $markerPath = Get-BootstrapNotepadPlusPlusMarkerPath -InstallInfo $installInfo
            Write-BootstrapJsonFile -Path $markerPath -Value ([ordered]@{
                curatedVersion = [string]$desired.curatedVersion
                architecture = 'x64'
                status = 'applied'
            })

            (Test-BootstrapNotepadPlusPlusConfigured -InstallInfo $installInfo -DesiredState $desired) | Should Be $true

            Microsoft.PowerShell.Management\Remove-Item -Path (Join-Path $pluginsRoot 'ComparePlus') -Recurse -Force
            (Test-BootstrapNotepadPlusPlusConfigured -InstallInfo $installInfo -DesiredState $desired) | Should Be $false
        } finally {
            if (Test-Path $root) {
                Microsoft.PowerShell.Management\Remove-Item -Path $root -Recurse -Force
            }
        }
    }
}
