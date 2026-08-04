#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

AUTOUATTEND_DIR=""

generate_autounattend() {
    local wim_index=1 lang="pt-BR" keyboard="pt-BR" timezone="America/Sao_Paulo"
    local user="phasezero" password="" disk_serial="" product_key=""
    local tpm_bypass=0 disk_id=0 autologon_count="" virtio=1

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
            --disk-id) disk_id="${2:-0}"; shift 2 ;;
            --disk-id=*) disk_id="${1#*=}"; shift ;;
            # Persistent by default so GRUB -> Windows-logged-in needs no human.
            # A finite count exists for password-policy installs.
            --autologon-count) autologon_count="${2:-}"; shift 2 ;;
            --autologon-count=*) autologon_count="${1#*=}"; shift ;;
            --no-virtio) virtio=0; shift ;;
            --output-dir) AUTOUATTEND_DIR="${2:-}"; shift 2 ;;
            --output-dir=*) AUTOUATTEND_DIR="${1#*=}"; shift ;;
            *) pz_error "unknown autounattend option: $1"; return 1 ;;
        esac
    done

    [ -n "$disk_serial" ] || { pz_error "--disk-serial required"; return 1; }
    # The serial is a guard token compared verbatim inside WinPE; anything that
    # needs escaping there would silently never match.
    [[ "$disk_serial" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || {
        pz_error "--disk-serial must be 1-32 chars of [A-Za-z0-9_-]"
        return 1
    }
    [[ "$disk_id" =~ ^[0-9]+$ ]] || { pz_error "--disk-id must be numeric"; return 1; }
    [ -z "$autologon_count" ] || [[ "$autologon_count" =~ ^[0-9]+$ ]] || {
        pz_error "--autologon-count must be numeric"
        return 1
    }
    [ -n "$AUTOUATTEND_DIR" ] || AUTOUATTEND_DIR="${PZ_STATE}/autounattend-$$"
    mkdir -p "$AUTOUATTEND_DIR"
    chmod 0700 "$AUTOUATTEND_DIR"

    local password_xml=""
    if [ -n "$password" ]; then
        password_xml="<Password>${password}</Password>"
    fi

    # Setup can only address the install target by 0-based index and wipes it
    # unconditionally, so the index alone is never a safe contract. The guard
    # runs first and aborts Setup unless the disk carries the expected serial.
    local guard_xml
    guard_xml="
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>cmd /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\\pz-disk-guard.cmd %i:\\pz-disk-guard.cmd ${disk_serial} ${disk_id}</Path>
                    <Description>PhaseZeroDiskTargetGuard</Description>
                    <Order>1</Order>
                    <WillReboot>Never</WillReboot>
                </RunSynchronousCommand>"

    local bypass_xml=""
    if [ "$tpm_bypass" = "1" ]; then
        bypass_xml="
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassTPMCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassTPMCheck</Description>
                    <Order>2</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassSecureBootCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassSecureBootCheck</Description>
                    <Order>3</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassRAMCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassRAMCheck</Description>
                    <Order>4</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassStorageCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassStorageCheck</Description>
                    <Order>5</Order>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassCPUCheck /t reg_dword /d 00000001 /f</Path>
                    <Description>BypassCPUCheck</Description>
                    <Order>6</Order>
                </RunSynchronousCommand>"
    fi

    # Without the virtio storage driver loaded in WinPE, Setup enumerates no
    # disk at all and the install dies before DiskConfiguration ever runs. The
    # virtio-win media is attached as a second CD; every drive letter is probed
    # because WinPE assigns them in no guaranteed order.
    local virtio_xml=""
    if [ "$virtio" = "1" ]; then
        virtio_xml="
        <component name=\"Microsoft-Windows-PnpCustomizationsWinPE\" processorArchitecture=\"amd64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">
            <DriverPaths>"
        local letter order=1
        for letter in D E F G H; do
            virtio_xml="$virtio_xml
                <PathAndCredentials wcm:action=\"add\" wcm:keyValue=\"${order}\">
                    <Path>${letter}:\\</Path>
                </PathAndCredentials>"
            order=$((order + 1))
        done
        virtio_xml="$virtio_xml
            </DriverPaths>
        </component>"
    fi

    # Omitting LogonCount makes AutoAdminLogon persistent, which is what a
    # turnkey GRUB -> Windows-logged-in boot needs. A finite count is only
    # emitted when the caller asks for one, e.g. a password-policy install that
    # just needs the first boot to reach the setup script.
    local autologon_count_xml=""
    if [ -n "$autologon_count" ]; then
        autologon_count_xml="
                <LogonCount>${autologon_count}</LogonCount>"
    fi

    local product_key_xml=""
    if [ -n "$product_key" ]; then
        [[ "$product_key" =~ ^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$ ]] || {
            pz_error "invalid product key format"
            return 1
        }
        product_key_xml="<ProductKey>
                    <Key>${product_key}</Key>
                    <WillShowUI>Never</WillShowUI>
                </ProductKey>"
    fi

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
            <Restart>Restart</Restart>
            <RunSynchronous>
                ${guard_xml}${bypass_xml}
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
                            <PartitionID>3</PartitionID>
                            <Label>Windows</Label>
                            <Format>NTFS</Format>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>${disk_id}</DiskID>
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
                        <DiskID>${disk_id}</DiskID>
                        <PartitionID>3</PartitionID>
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
        </component>${virtio_xml}
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>${keyboard}</InputLocale>
            <SystemLocale>${lang}</SystemLocale>
            <UILanguage>${lang}</UILanguage>
            <UserLocale>${lang}</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <AutoLogon>
                <Password>
                    <Value>${password}</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>${autologon_count_xml}
                <Username>${user}</Username>
            </AutoLogon>
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
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>PhaseZero guest setup</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                    <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "\$script = \$null; foreach (\$code in 68..90) { \$candidate = ([char]\$code) + ':\setup.ps1'; if (Test-Path \$candidate) { \$script = \$candidate; break } }; if (-not \$script) { exit 2 }; &amp; \$script"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
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
    validate_autounattend "$AUTOUATTEND_DIR/autounattend.xml" "$disk_serial" || {
        rm -f "$AUTOUATTEND_DIR/autounattend.xml"
        return 1
    }
    # The guard is useless if it is not on the answer media next to the XML.
    install -m 0644 "$PZ_ROOT/linux/windows-vm/assets/pz-disk-guard.cmd" \
        "$AUTOUATTEND_DIR/pz-disk-guard.cmd" || {
        pz_error "could not stage pz-disk-guard.cmd next to the answer file"
        rm -f "$AUTOUATTEND_DIR/autounattend.xml"
        return 1
    }
    pz_info "generated: $AUTOUATTEND_DIR/autounattend.xml (target guard: $disk_serial)"
    echo "$AUTOUATTEND_DIR/autounattend.xml"
}

# A malformed or silently-truncated answer file turns into a Setup that stops
# at an interactive prompt hours later, or worse, one that ignores the section
# it could not parse. Fail at generation instead.
validate_autounattend() {
    local file="$1" expected_serial="$2" missing=()
    if command -v xmllint >/dev/null 2>&1; then
        xmllint --noout "$file" 2>/dev/null || {
            pz_error "generated autounattend.xml is not well-formed XML"
            return 1
        }
    else
        python3 -c "import sys,xml.dom.minidom as m; m.parse(sys.argv[1])" "$file" 2>/dev/null || {
            pz_error "generated autounattend.xml is not well-formed XML"
            return 1
        }
    fi
    local marker
    for marker in '<settings pass="windowsPE">' '<settings pass="oobeSystem">' \
        '<settings pass="specialize">' 'PhaseZeroDiskTargetGuard' \
        '<WillWipeDisk>true</WillWipeDisk>' '<ImageInstall>'; do
        grep -Fq "$marker" "$file" || missing+=("$marker")
    done
    # The wipe must never be reachable without the guard that authorises it.
    grep -Fq "pz-disk-guard.cmd $expected_serial " "$file" ||
        missing+=("disk guard invocation for serial $expected_serial")
    if [ "${#missing[@]}" -gt 0 ]; then
        pz_error "generated autounattend.xml is missing: ${missing[*]}"
        return 1
    fi
    # Unattend rejects duplicate Order values among siblings. Comparing them
    # per parent matters: CreatePartitions and RunSynchronous both legitimately
    # start at 1, so a flat scan of the document reports collisions that do not
    # exist and hides the ones that do.
    python3 - "$file" <<'PYEOF' || return 1
import sys, xml.etree.ElementTree as ET
ns = '{urn:schemas-microsoft-com:unattend}'
tree = ET.parse(sys.argv[1])
bad = []
for parent in tree.iter():
    orders = [c.findtext(f'{ns}Order') for c in parent
              if c.findtext(f'{ns}Order') is not None]
    dupes = {o for o in orders if orders.count(o) > 1}
    if dupes:
        bad.append(f"{parent.tag.replace(ns,'')}: {sorted(dupes)}")
if bad:
    print('duplicate sibling <Order> values: ' + '; '.join(bad), file=sys.stderr)
    sys.exit(1)
PYEOF
    return 0
}

case "${1:-generate}" in
    generate) shift; generate_autounattend "$@" ;;
    *) echo "usage: autounattend generate [options]"; exit 1 ;;
esac
