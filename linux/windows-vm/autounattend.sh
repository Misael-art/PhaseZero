#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

AUTOUATTEND_DIR=""

generate_autounattend() {
    local wim_index=1 lang="pt-BR" keyboard="pt-BR" timezone="America/Sao_Paulo"
    local user="phasezero" password="" disk_serial="" product_key=""
    local tpm_bypass=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --wim-index) wim_index="${2:-1}"; shift 2 ;;
            --wim-index=*) wim_index="${1#*=}"; shift ;;
            --lang) lang="${2:-}"; shift 2 ;;
            --lang=*) lang="${1#*=}"; shift ;;
            --keyboard) keyboard="${2:-}"; shift 2 ;;
            --keyboard=*) keyboard="${1#*=}"; shift ;;
            --timezone) timezone="${2:-}"; shift 2 ;;
            --timezone=*) timezone="${1#*=}"; shift ;;
            --user) user="${2:-phasezero}"; shift 2 ;;
            --user=*) user="${1#*=}"; shift ;;
            --password) password="${2:-}"; shift 2 ;;
            --password=*) password="${1#*=}"; shift ;;
            --disk-serial) disk_serial="${2:-}"; shift 2 ;;
            --disk-serial=*) disk_serial="${1#*=}"; shift ;;
            --product-key) product_key="${2:-}"; shift 2 ;;
            --product-key=*) product_key="${1#*=}"; shift ;;
            --tpm-bypass) tpm_bypass=1; shift ;;
            --output-dir) AUTOUATTEND_DIR="${2:-}"; shift 2 ;;
            --output-dir=*) AUTOUATTEND_DIR="${1#*=}"; shift ;;
            *) pz_error "unknown autounattend option: $1"; return 1 ;;
        esac
    done

    [ -n "$disk_serial" ] || { pz_error "--disk-serial required"; return 1; }
    [ -n "$AUTOUATTEND_DIR" ] || AUTOUATTEND_DIR="${PZ_STATE}/autounattend-$$"
    mkdir -p "$AUTOUATTEND_DIR"
    chmod 0700 "$AUTOUATTEND_DIR"

    local password_xml=""
    if [ -n "$password" ]; then
        password_xml="<Password>${password}</Password>"
    fi

    local bypass_xml=""
    if [ "$tpm_bypass" = "1" ]; then
        bypass_xml="
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassTPMCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassTPMCheck</Description>
                    <Order>1</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassSecureBootCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassSecureBootCheck</Description>
                    <Order>2</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassRAMCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassRAMCheck</Description>
                    <Order>3</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassStorageCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassStorageCheck</Description>
                    <Order>4</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassCPUCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassCPUCheck</Description>
                    <Order>5</Order>
                </RunSynchronousCommand>"
    fi

    local product_key_xml=""
    [ -n "$product_key" ] && product_key_xml="<ProductKey>${product_key}</ProductKey>"

    cat > "$AUTOUATTEND_DIR/autounattend.xml" << AUTOUNATTENDEOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
                <FullName>${user}</FullName>
                <Organization>PhaseZero</Organization>
                ${product_key_xml}
            </UserData>
            <EnableFirewall>true</EnableFirewall>
            <EnableNetwork>true</EnableNetwork>
            <Restart>restart</Restart>
            <RunSynchronous>
                ${bypass_xml}
            </RunSynchronous>
            <DiskConfiguration>
                <WillShowUI>Never</WillShowUI>
                <Disk wcm:action="add">
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Size>500</Size>
                            <Type>EFI</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Size>16</Size>
                            <Type>MSR</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Size>100</Size>
                            <Type>Recovery</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>4</Order>
                            <Extend>true</Extend>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Label>System</Label>
                            <Format>FAT32</Format>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>2</PartitionID>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>3</Order>
                            <PartitionID>4</PartitionID>
                            <Label>Windows</Label>
                            <Format>NTFS</Format>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>4</Order>
                            <PartitionID>3</PartitionID>
                            <Label>WinRE</Label>
                            <Type>Recovery</Type>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>${wim_index}</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>4</PartitionID>
                    </InstallTo>
                </OSImage>
            </ImageInstall>
        </component>
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <SetupUILanguage>
                <UILanguage>${lang}</UILanguage>
            </SetupUILanguage>
            <InputLocale>${keyboard}</InputLocale>
            <SystemLocale>${lang}</SystemLocale>
            <UILanguage>${lang}</UILanguage>
            <UserLocale>${lang}</UserLocale>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>${keyboard}</InputLocale>
            <SystemLocale>${lang}</SystemLocale>
            <UILanguage>${lang}</UILanguage>
            <UserLocale>${lang}</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value>${password}</Value>
                            <PlainText>true</PlainText>
                        </Password>
                        <Description>PhaseZero managed account</Description>
                        <DisplayName>${user}</DisplayName>
                        <Group>Administrators</Group>
                        <Name>${user}</Name>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Home</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <RegisteredOrganization>PhaseZero</RegisteredOrganization>
            <RegisteredOwner>${user}</RegisteredOwner>
            <TimeZone>${timezone}</TimeZone>
            <ShowWindowsLive>false</ShowWindowsLive>
            <BluetoothTaskbarIconEnabled>false</BluetoothTaskbarIconEnabled>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Path>powershell -Command \"Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -Value 1\"</Path>
                    <Description>EnableUAC</Description>
                    <Order>1</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Path>powershell -Command \"Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 1\"</Path>
                    <Description>SetTelemetryBasic</Description>
                    <Order>2</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Path>powershell -Command \"Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -Value 1\"</Path>
                    <Description>SetTelemetryBasic2</Description>
                    <Order>3</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Path>powershell -Command \"Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name 'PrivacyConsentStatus' -ErrorAction SilentlyContinue\"</Path>
                    <Description>ClearPrivacyConsent</Description>
                    <Order>4</Order>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RegisteredOrganization>PhaseZero</RegisteredOrganization>
            <RegisteredOwner>${user}</RegisteredOwner>
            <TimeZone>${timezone}</TimeZone>
            <DoNotCleanTaskBar>true</DoNotCleanTaskBar>
        </component>
    </settings>
</unattend>
AUTOUNATTENDEOF

    chmod 0600 "$AUTOUATTEND_DIR/autounattend.xml"
    pz_info "generated: $AUTOUATTEND_DIR/autounattend.xml"
    echo "$AUTOUATTEND_DIR/autounattend.xml"
}

case "${1:-generate}" in
    generate) shift; generate_autounattend "$@" ;;
    *) echo "usage: autounattend generate [options]"; exit 1 ;;
esac
