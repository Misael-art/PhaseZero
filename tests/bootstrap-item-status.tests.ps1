$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

function New-StatusTestRoot {
    $root = Join-Path $env:TEMP ("bootstrap_itemstatus_{0}" -f ([Guid]::NewGuid().ToString('N')))
    $env:BOOTSTRAP_DATA_ROOT = $root
    Remove-Variable -Scope Script -Name BootstrapDataRoot -ErrorAction SilentlyContinue
    return $root
}

Describe 'Item status engine (visual status signals)' {
    It 'declares the five-state model with the expected colors' {
        . $scriptPath -BootstrapUiLibraryMode
        $info = @(Get-BootstrapItemStatusInfo)
        $info.Count | Should Be 5
        $map = @{}
        foreach ($i in $info) { $map[[string]$i.status] = [string]$i.color }
        $map['error'] | Should Be 'Red'
        $map['not-installed'] | Should Be 'White'
        $map['installed-unconfigured'] | Should Be 'Yellow'
        $map['configured'] | Should Be 'Blue'
        $map['optimized-tested'] | Should Be 'Green'
    }

    It 'maps every status to its console color' {
        . $scriptPath -BootstrapUiLibraryMode
        (Get-BootstrapItemStatusColor -Status 'error') | Should Be 'Red'
        (Get-BootstrapItemStatusColor -Status 'not-installed') | Should Be 'White'
        (Get-BootstrapItemStatusColor -Status 'installed-unconfigured') | Should Be 'Yellow'
        (Get-BootstrapItemStatusColor -Status 'configured') | Should Be 'Blue'
        (Get-BootstrapItemStatusColor -Status 'optimized-tested') | Should Be 'Green'
    }

    It 'returns not-installed when no probe path or command resolves' {
        . $scriptPath -BootstrapUiLibraryMode
        $null = New-StatusTestRoot
        $gone = Join-Path $env:TEMP 'pz-itemstatus-absent.exe'
        (Get-BootstrapItemStatus -Kind 'app' -Id 'absent-x' -ProbePaths @($gone)) | Should Be 'not-installed'
    }

    It 'returns installed-unconfigured when installed but without persisted status' {
        . $scriptPath -BootstrapUiLibraryMode
        $null = New-StatusTestRoot
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        (Get-BootstrapItemStatus -Kind 'app' -Id 'cmd-x' -ProbePaths @($cmd)) | Should Be 'installed-unconfigured'
    }

    It 'surfaces the error state even when the item is not installed' {
        . $scriptPath -BootstrapUiLibraryMode
        $null = New-StatusTestRoot
        $gone = Join-Path $env:TEMP 'pz-itemstatus-absent.exe'
        (Get-BootstrapItemStatus -Kind 'tool' -Id 'err-x' -ProbePaths @($gone) -ErrorFlag) | Should Be 'error'
        Set-BootstrapItemStatus -Kind 'tool' -Id 'err-y' -Status 'error'
        (Get-BootstrapItemStatus -Kind 'tool' -Id 'err-y') | Should Be 'error'
    }

    It 'promotes installed items to the persisted configured/optimized state' {
        . $scriptPath -BootstrapUiLibraryMode
        $null = New-StatusTestRoot
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        Set-BootstrapItemStatus -Kind 'app' -Id 'cmd-x' -Status 'configured'
        (Get-BootstrapItemStatus -Kind 'app' -Id 'cmd-x' -ProbePaths @($cmd)) | Should Be 'configured'
        Set-BootstrapItemStatus -Kind 'app' -Id 'cmd-x' -Status 'optimized-tested'
        (Get-BootstrapItemStatus -Kind 'app' -Id 'cmd-x' -ProbePaths @($cmd)) | Should Be 'optimized-tested'
    }

    It 'downgrades to not-installed when the binary disappears despite a cached status' {
        . $scriptPath -BootstrapUiLibraryMode
        $null = New-StatusTestRoot
        $gone = Join-Path $env:TEMP 'pz-itemstatus-absent.exe'
        Set-BootstrapItemStatus -Kind 'app' -Id 'cmd-x' -Status 'optimized-tested'
        (Get-BootstrapItemStatus -Kind 'app' -Id 'cmd-x' -ProbePaths @($gone)) | Should Be 'not-installed'
    }
}
