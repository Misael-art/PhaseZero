$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'bootstrap-tools.ps1'
. $scriptPath -BootstrapUiLibraryMode

Describe 'Steam Deck HOME discovery' {
    $deckRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pz-deck-' + [guid]::NewGuid().ToString('N'))
    $emuRoot = Join-Path $deckRoot '@\deck\Emulation'

    BeforeEach {
        New-Item -ItemType Directory -Path (Join-Path $emuRoot 'roms') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $emuRoot 'bios') -Force | Out-Null
    }
    AfterEach {
        if (Test-Path -LiteralPath $deckRoot) { Remove-Item -LiteralPath $deckRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'finds and validates a Deck Emulation tree on a Btrfs-looking volume' {
        Mock Get-BootstrapCandidateVolumeRoots { @([pscustomobject]@{ Root = ($deckRoot + '\'); DriveLetter = 'Z'; FileSystem = 'Btrfs' }) }
        Mock Get-BootstrapLinuxPartitions { @(@{ DiskNumber = 0; PartitionNumber = 5 }) }

        $deckInfo = Get-BootstrapSteamDeckHome -ScanVolumes
        $deckInfo.found | Should Be $true
        $deckInfo.emulationRoot | Should Be $emuRoot
        @($deckInfo.validationReasons).Count | Should Be 0
    }

    It 'rejects a tree with no EmuDeck markers' {
        Remove-Item -LiteralPath (Join-Path $emuRoot 'roms') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $emuRoot 'bios') -Recurse -Force
        Mock Get-BootstrapCandidateVolumeRoots { @([pscustomobject]@{ Root = ($deckRoot + '\'); DriveLetter = 'Z'; FileSystem = 'Btrfs' }) }
        Mock Get-BootstrapLinuxPartitions { @() }

        $deckInfo = Get-BootstrapSteamDeckHome -ScanVolumes
        $deckInfo.found | Should Be $false
        @($deckInfo.validationReasons) -contains 'no-emudeck-markers' | Should Be $true
    }

    It 'rejects markers on an NTFS volume with no Linux partition (not Linux-backed)' {
        Mock Get-BootstrapCandidateVolumeRoots { @([pscustomobject]@{ Root = ($deckRoot + '\'); DriveLetter = 'Z'; FileSystem = 'NTFS' }) }
        Mock Get-BootstrapLinuxPartitions { @() }

        $deckInfo = Get-BootstrapSteamDeckHome -ScanVolumes
        $deckInfo.found | Should Be $false
        @($deckInfo.validationReasons) -contains 'volume-not-linux-backed' | Should Be $true
    }

    It 'returns not-found when no volume holds an Emulation tree' {
        Mock Get-BootstrapCandidateVolumeRoots { @([pscustomobject]@{ Root = 'Q:\'; DriveLetter = 'Q'; FileSystem = 'NTFS' }) }
        Mock Get-BootstrapLinuxPartitions { @() }

        $deckInfo = Get-BootstrapSteamDeckHome -ScanVolumes
        $deckInfo.found | Should Be $false
    }

    It 'is a no-op in library mode without -ScanVolumes' {
        $deckInfo = Get-BootstrapSteamDeckHome
        $deckInfo.found | Should Be $false
    }
}

Describe 'Steam Deck HOME discovery component catalog' {
    It 'registers the read-only detection + media + shortcuts components as builtin' {
        $catalog = Get-BootstrapComponentCatalog
        foreach ($id in @('steamdeck-home-detect', 'emulation-deck-shared-media', 'emulation-desktop-shortcuts')) {
            $catalog.Contains($id) | Should Be $true
            [string]$catalog[$id].Kind | Should Be 'builtin'
        }
        @($catalog['steamdeck-home-detect'].DependsOn) -contains 'winbtrfs' | Should Be $true
    }
}
