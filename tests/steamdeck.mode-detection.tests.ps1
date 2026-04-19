$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$detectScriptPath = Join-Path $repoRoot 'assets\steamdeck\automation\Detect-Mode.ps1'

function Invoke-DetectMode {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][hashtable]$MockState
    )

    $settingsPath = Join-Path $env:TEMP ("steamdeck_settings_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $mockPath = Join-Path $env:TEMP ("steamdeck_state_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    try {
        $Settings | ConvertTo-Json -Depth 12 | Set-Content -Path $settingsPath -Encoding utf8
        $MockState | ConvertTo-Json -Depth 12 | Set-Content -Path $mockPath -Encoding utf8
        $json = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $detectScriptPath -SettingsPath $settingsPath -MockStatePath $mockPath
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

Describe 'Steam Deck mode detection' {
    It 'detects handheld mode' {
        $result = Invoke-DetectMode -Settings $baseSettings -MockState @{
            battery = @{ onAcPower = $false }
            internalDisplay = @{
                manufacturer = 'VLV'
                product = 'ANX7530 U'
                isActive = $true
            }
            externalDisplays = @()
        }

        $result.mode | Should Be 'HANDHELD'
        $result.sessionProfile | Should Be 'game-handheld'
    }

    It 'detects docked monitor mode for multiple serials' {
        foreach ($serial in @('A', 'B')) {
            $result = Invoke-DetectMode -Settings $baseSettings -MockState @{
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
                        serial = $serial
                        instanceName = "DISPLAY\GSM7714\$serial"
                        isPrimary = ($serial -eq 'A')
                        isActive = $true
                    }
                )
            }

            $result.mode | Should Be 'DOCKED_MONITOR'
            $result.sessionProfile | Should Be 'desktop'
        }
    }

    It 'falls back to generic external mode for unknown displays' {
        $result = Invoke-DetectMode -Settings $baseSettings -MockState @{
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

        $result.mode | Should Be 'DOCKED_TV'
        $result.sessionProfile | Should Be 'game-docked'
    }

    It 'prefers the matched family when multiple displays are present' {
        $result = Invoke-DetectMode -Settings $baseSettings -MockState @{
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

        $result.mode | Should Be 'DOCKED_MONITOR'
        $result.sessionProfile | Should Be 'desktop'
    }

    It 'supports the legacy object schema for monitor families' {
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

        $result = Invoke-DetectMode -Settings $objectSchemaSettings -MockState @{
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

        $result.mode | Should Be 'DOCKED_MONITOR'
        $result.sessionProfile | Should Be 'desktop'
    }
}
