$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'

Describe 'winget portable / per-user artifact detection' {
    It 'detects a winget portable package exe under LOCALAPPDATA\Microsoft\WinGet\Packages\<Id>_*' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = Join-Path $env:TEMP ("pz-wgportable-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $pkgDir = Join-Path $work 'Microsoft\WinGet\Packages\OBSProject.OBSStudio_Microsoft.Winget.Source_8wekyb3d8bbwe\bin\64bit'
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        Set-Content -Path (Join-Path $pkgDir 'obs64.exe') -Value 'stub' -Encoding Ascii
        $prev = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $work
            Test-BootstrapWingetPortableArtifact -Id 'OBSProject.OBSStudio' | Should Be $true
            Test-BootstrapWingetPortableArtifact -Id 'Some.MissingPackage' | Should Be $false
            Test-BootstrapWingetPortableArtifact -Id '' | Should Be $false
        } finally {
            $env:LOCALAPPDATA = $prev
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns false when the package folder has no executable' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = Join-Path $env:TEMP ("pz-wgportable-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $pkgDir = Join-Path $work 'Microsoft\WinGet\Packages\Empty.Package_src\data'
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        Set-Content -Path (Join-Path $pkgDir 'readme.txt') -Value 'no exe' -Encoding Ascii
        $prev = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $work
            Test-BootstrapWingetPortableArtifact -Id 'Empty.Package' | Should Be $false
        } finally {
            $env:LOCALAPPDATA = $prev
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Test-BootstrapPackageArtifactsPresent uses the winget portable fallback when ProbePaths miss' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = Join-Path $env:TEMP ("pz-wgportable-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $pkgDir = Join-Path $work 'Microsoft\WinGet\Packages\OBSProject.OBSStudio_x\bin\64bit'
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        Set-Content -Path (Join-Path $pkgDir 'obs64.exe') -Value 'stub' -Encoding Ascii
        $prev = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $work
            Test-BootstrapPackageArtifactsPresent -ProbePaths @('C:\definitely\missing\obs64.exe') -WingetId 'OBSProject.OBSStudio' | Should Be $true
            Test-BootstrapPackageArtifactsPresent -ProbePaths @('C:\definitely\missing\obs64.exe') -WingetId 'OBSProject.OBSStudio' -AppxPackageNames @() | Should Be $true
            Test-BootstrapPackageArtifactsPresent -ProbePaths @('C:\definitely\missing\obs64.exe') | Should Be $false
        } finally {
            $env:LOCALAPPDATA = $prev
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'obs-studio and treesize-free catalog entries include the real install locations in ProbePaths' {
        . $scriptPath -BootstrapUiLibraryMode
        $catalog = Get-BootstrapComponentCatalog
        $obs = @($catalog['obs-studio'].ProbePaths)
        ($obs -join '|') | Should Match 'WinGet\\Packages\\OBSProject\.OBSStudio'
        $tree = @($catalog['treesize-free'].ProbePaths)
        ($tree -join '|') | Should Match 'LOCALAPPDATA|Programs\\JAM Software\\TreeSize Free'
    }

    It 'Get-BootstrapItemStatus detects a winget-portable install via -WingetId when ProbePaths miss' {
        . $scriptPath -BootstrapUiLibraryMode
        $work = Join-Path $env:TEMP ("pz-st-{0}" -f ([Guid]::NewGuid().ToString('N')))
        $pkg = Join-Path $work 'Microsoft\WinGet\Packages\OBSProject.OBSStudio_x\bin\64bit'
        New-Item -ItemType Directory -Path $pkg -Force | Out-Null
        Set-Content -Path (Join-Path $pkg 'obs64.exe') -Value 'x' -Encoding Ascii
        $prev = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $work
            Get-BootstrapItemStatus -Kind 'app' -Id 'obs-studio' -ProbePaths @('C:\nope\x.exe') -WingetId 'OBSProject.OBSStudio' -Cache @{} | Should Be 'installed-unconfigured'
            Get-BootstrapItemStatus -Kind 'app' -Id 'obs-studio' -ProbePaths @('C:\nope\x.exe') -Cache @{} | Should Be 'not-installed'
        } finally {
            $env:LOCALAPPDATA = $prev
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Get-BootstrapComponentStatusMap returns a status for every catalog component' {
        . $scriptPath -BootstrapUiLibraryMode
        $map = Get-BootstrapComponentStatusMap
        $catalog = Get-BootstrapComponentCatalog
        @($map.Keys).Count | Should Be @($catalog.Keys).Count
        $valid = @('error','not-installed','installed-unconfigured','configured','optimized-tested')
        foreach ($v in @($map.Values)) { ($valid -contains [string]$v) | Should Be $true }
    }
}
