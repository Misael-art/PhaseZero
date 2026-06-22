$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $repoRoot 'assets\steamdeck\automation\SteamDeck.Common.ps1'
. $commonPath

Describe 'ModeWatcher decision (debounce / cooldown / no re-apply)' {
    It 'does not apply until the mode is stable for StableSamples' {
        $d1 = Get-SteamDeckModeWatcherDecision -DetectedMode 'HANDHELD' -State $null -StableSamples 2 -CooldownSeconds 5
        [int]$d1.State['candidateCount'] | Should Be 1
        [bool]$d1.ShouldApply | Should Be $false

        $d2 = Get-SteamDeckModeWatcherDecision -DetectedMode 'HANDHELD' -State $d1.State -StableSamples 2 -CooldownSeconds 5
        [int]$d2.State['candidateCount'] | Should Be 2
        [bool]$d2.ShouldApply | Should Be $true
        [string]$d2.ApplyMode | Should Be 'HANDHELD'
    }

    It 'resets the candidate counter when the detected mode changes' {
        $a = Get-SteamDeckModeWatcherDecision -DetectedMode 'HANDHELD' -State $null -StableSamples 2 -CooldownSeconds 5
        $b = Get-SteamDeckModeWatcherDecision -DetectedMode 'DOCKED_TV' -State $a.State -StableSamples 2 -CooldownSeconds 5
        [string]$b.State['lastCandidateMode'] | Should Be 'DOCKED_TV'
        [int]$b.State['candidateCount'] | Should Be 1
        [bool]$b.ShouldApply | Should Be $false
    }

    It 'does not re-apply a mode that is already the last applied' {
        $state = @{ lastCandidateMode = 'HANDHELD'; candidateCount = 5; lastAppliedMode = 'HANDHELD'; lastAppliedAt = $null }
        $d = Get-SteamDeckModeWatcherDecision -DetectedMode 'HANDHELD' -State $state -StableSamples 2 -CooldownSeconds 5
        [bool]$d.ShouldApply | Should Be $false
    }

    It 'respects the cooldown window before applying a new mode' {
        $now = Get-Date
        $state = @{ lastCandidateMode = 'DOCKED_TV'; candidateCount = 2; lastAppliedMode = 'HANDHELD'; lastAppliedAt = $now.AddSeconds(-1).ToString('o') }
        $cooling = Get-SteamDeckModeWatcherDecision -DetectedMode 'DOCKED_TV' -State $state -StableSamples 2 -CooldownSeconds 5 -Now $now
        [bool]$cooling.CooldownReady | Should Be $false
        [bool]$cooling.ShouldApply | Should Be $false

        $state2 = @{ lastCandidateMode = 'DOCKED_TV'; candidateCount = 2; lastAppliedMode = 'HANDHELD'; lastAppliedAt = $now.AddSeconds(-30).ToString('o') }
        $ready = Get-SteamDeckModeWatcherDecision -DetectedMode 'DOCKED_TV' -State $state2 -StableSamples 2 -CooldownSeconds 5 -Now $now
        [bool]$ready.CooldownReady | Should Be $true
        [bool]$ready.ShouldApply | Should Be $true
    }

    It 'never applies an empty / unknown detected mode' {
        $state = @{ lastCandidateMode = ''; candidateCount = 9; lastAppliedMode = 'HANDHELD'; lastAppliedAt = $null }
        $d = Get-SteamDeckModeWatcherDecision -DetectedMode '' -State $state -StableSamples 2 -CooldownSeconds 5
        [bool]$d.ShouldApply | Should Be $false
    }
}
