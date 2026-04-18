$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$detectScriptPath = Join-Path $repoRoot 'assets\steamdeck\automation\Detect-Mode.ps1'

function Assert-Mode {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedMode,
        [Parameter(Mandatory = $true)][object]$Actual
    )

    if ($Actual.mode -ne $ExpectedMode) {
        throw "Expected mode $ExpectedMode but got $($Actual.mode)`n$($Actual | ConvertTo-Json -Depth 8)"
    }
}

function Assert-SessionProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedProfile,
        [Parameter(Mandatory = $true)][object]$Actual
    )

    if ($Actual.sessionProfile -ne $ExpectedProfile) {
        throw "Expected sessionProfile $ExpectedProfile but got $($Actual.sessionProfile)`n$($Actual | ConvertTo-Json -Depth 8)"
    }
}

function Invoke-DetectMode {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][hashtable]$MockState
    )

    if (-not (Test-Path $detectScriptPath)) {
        throw "Detect-Mode.ps1 not found at $detectScriptPath"
    }

    $settingsPath = Join-Path $env:TEMP ("steamdeck_settings_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $mockPath = Join-Path $env:TEMP ("steamdeck_state_{0}.json" -f ([guid]::NewGuid().ToString('N')))

    try {
        $Settings | ConvertTo-Json -Depth 12 | Set-Content -Path $settingsPath -Encoding utf8
        $MockState | ConvertTo-Json -Depth 12 | Set-Content -Path $mockPath -Encoding utf8
        $json = & powershell -NoProfile -ExecutionPolicy Bypass -File $detectScriptPath -SettingsPath $settingsPath -MockStatePath $mockPath
        return ($json | ConvertFrom-Json)
    } finally {
        if (Test-Path $settingsPath) { Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $mockPath) { Remove-Item $mockPath -Force -ErrorAction SilentlyContinue }
    }
}

$baseSettings = @{
    steamDeckVersion = 'Auto'
    internalDisplay = @{
        manufacturer = 'VLV'
        product = 'ANX7530 U'
    }
    monitorProfiles = @()
    monitorFamilies = @(
        @{
            manufacturer = 'GSM'
            product = 'LG HDR WFHD'
            mode = 'DOCKED_MONITOR'
            layout = 'lg-hdr-wfhd'
            resolutionPolicy = 'native-prefer-1440p-else-1080p'
        }
    )
    genericExternal = @{
        mode = 'DOCKED_TV'
        resolutionPolicy = '1920x1080-safe'
        layout = 'external-generic'
    }
}

$handheld = Invoke-DetectMode -Settings $baseSettings -MockState @{
    battery = @{ onAcPower = $false }
    internalDisplay = @{
        manufacturer = 'VLV'
        product = 'ANX7530 U'
        isActive = $true
    }
    externalDisplays = @()
}
Assert-Mode -ExpectedMode 'HANDHELD' -Actual $handheld
Assert-SessionProfile -ExpectedProfile 'game-handheld' -Actual $handheld

$lgSerialA = Invoke-DetectMode -Settings $baseSettings -MockState @{
    battery = @{ onAcPower = $true }
    internalDisplay = @{
        manufacturer = 'VLV'
        product = 'ANX7530 U'
        isActive = $true
    }
    externalDisplays = @(
        @{
            manufacturer = 'GSM'
            product = 'LG HDR WFHD'
            serial = 'A'
            instanceName = 'DISPLAY\GSM7714\A'
            isPrimary = $true
            isActive = $true
        }
    )
}
Assert-Mode -ExpectedMode 'DOCKED_MONITOR' -Actual $lgSerialA
Assert-SessionProfile -ExpectedProfile 'desktop' -Actual $lgSerialA

$lgSerialB = Invoke-DetectMode -Settings $baseSettings -MockState @{
    battery = @{ onAcPower = $true }
    internalDisplay = @{
        manufacturer = 'VLV'
        product = 'ANX7530 U'
        isActive = $true
    }
    externalDisplays = @(
        @{
            manufacturer = 'GSM'
            product = 'LG HDR WFHD'
            serial = 'B'
            instanceName = 'DISPLAY\GSM7714\B'
            isPrimary = $false
            isActive = $true
        }
    )
}
Assert-Mode -ExpectedMode 'DOCKED_MONITOR' -Actual $lgSerialB
Assert-SessionProfile -ExpectedProfile 'desktop' -Actual $lgSerialB

$unknownExternal = Invoke-DetectMode -Settings $baseSettings -MockState @{
    battery = @{ onAcPower = $true }
    internalDisplay = @{
        manufacturer = 'VLV'
        product = 'ANX7530 U'
        isActive = $true
    }
    externalDisplays = @(
        @{
            manufacturer = 'DEL'
            product = 'Dell U2720Q'
            serial = 'XYZ'
            instanceName = 'DISPLAY\DEL0001\XYZ'
            isPrimary = $true
            isActive = $true
        }
    )
}
Assert-Mode -ExpectedMode 'DOCKED_TV' -Actual $unknownExternal
Assert-SessionProfile -ExpectedProfile 'game-docked' -Actual $unknownExternal

$mixedDisplays = Invoke-DetectMode -Settings $baseSettings -MockState @{
    battery = @{ onAcPower = $true }
    internalDisplay = @{
        manufacturer = 'VLV'
        product = 'ANX7530 U'
        isActive = $true
    }
    externalDisplays = @(
        @{
            manufacturer = 'DEL'
            product = 'Dell U2720Q'
            serial = 'XYZ'
            instanceName = 'DISPLAY\DEL0001\XYZ'
            isPrimary = $false
            isActive = $true
        },
        @{
            manufacturer = 'GSM'
            product = 'LG HDR WFHD'
            serial = 'PRIMARY'
            instanceName = 'DISPLAY\GSM7714\PRIMARY'
            isPrimary = $true
            isActive = $true
        }
    )
}
Assert-Mode -ExpectedMode 'DOCKED_MONITOR' -Actual $mixedDisplays
Assert-SessionProfile -ExpectedProfile 'desktop' -Actual $mixedDisplays

$objectSchemaSettings = @{
    steamDeckVersion = 'Auto'
    internalDisplay = @{
        manufacturer = 'VLV'
        product = 'ANX7530 U'
    }
    monitorProfiles = @{}
    monitorFamilies = @{
        manufacturer = 'GSM'
        product = 'LG HDR WFHD'
        mode = 'DOCKED_MONITOR'
        layout = 'lg-hdr-wfhd'
        resolutionPolicy = 'native-prefer-1440p-else-1080p'
    }
    genericExternal = @{
        mode = 'DOCKED_TV'
        resolutionPolicy = '1920x1080-safe'
        layout = 'external-generic'
    }
}

$objectSchemaFamily = Invoke-DetectMode -Settings $objectSchemaSettings -MockState @{
    battery = @{ onAcPower = $true }
    internalDisplay = @{
        manufacturer = 'VLV'
        product = 'ANX7530 U'
        isActive = $true
    }
    externalDisplays = @(
        @{
            manufacturer = 'GSM'
            product = 'LG HDR WFHD'
            serial = 'OBJ'
            instanceName = 'DISPLAY\GSM7714\OBJ'
            isPrimary = $true
            isActive = $true
        }
    )
}
Assert-Mode -ExpectedMode 'DOCKED_MONITOR' -Actual $objectSchemaFamily
Assert-SessionProfile -ExpectedProfile 'desktop' -Actual $objectSchemaFamily

Write-Host 'steamdeck.mode-detection.tests.ps1: PASS'
