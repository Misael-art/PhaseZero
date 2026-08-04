@echo off
setlocal enabledelayedexpansion
rem PhaseZero install target guard.
rem
rem Windows Setup's DiskConfiguration can only address a disk by its 0-based
rem index, and it wipes it unconditionally. On a machine with more than one
rem disk the index is not stable, so an unattended install driven purely by
rem DiskID is one enumeration change away from destroying the wrong drive.
rem
rem This runs in windowsPE before ImageInstall and refuses to continue unless
rem the disk at the configured index carries the serial PhaseZero expects.
rem A non-zero exit aborts Setup, which is the safe outcome: no partition table
rem is touched.
rem
rem Deliberately cmd + wmic, not PowerShell: the Setup WinPE image ships
rem diskpart.exe and WMIC.exe but has no powershell.exe and no Storage module,
rem so a PowerShell guard would silently never run.

set "EXPECTED=%~1"
set "DISKID=%~2"
if "%EXPECTED%"=="" goto :badargs
if "%DISKID%"=="" set "DISKID=0"

set "LOG=%SystemDrive%\pz-disk-guard.log"
echo [%DATE% %TIME%] guard start expected=%EXPECTED% diskid=%DISKID%>>"%LOG%"

set "FOUND="
for /f "skip=1 tokens=*" %%A in ('wmic diskdrive where "Index=%DISKID%" get SerialNumber 2^>nul') do (
    if not defined FOUND (
        set "LINE=%%A"
        rem Strip the trailing CR and padding wmic emits on every row.
        for /f "tokens=* delims= " %%B in ("!LINE!") do set "LINE=%%B"
        set "LINE=!LINE: =!"
        if not "!LINE!"=="" set "FOUND=!LINE!"
    )
)

if not defined FOUND (
    echo [%DATE% %TIME%] FAIL: no disk at index %DISKID%>>"%LOG%"
    exit /b 2
)

echo [%DATE% %TIME%] found=!FOUND!>>"%LOG%"
if /i not "!FOUND!"=="%EXPECTED%" (
    echo [%DATE% %TIME%] REFUSING: disk %DISKID% serial !FOUND! is not %EXPECTED%>>"%LOG%"
    exit /b 3
)

echo [%DATE% %TIME%] OK: target confirmed>>"%LOG%"
exit /b 0

:badargs
echo missing expected serial argument>>"%SystemDrive%\pz-disk-guard.log"
exit /b 4
