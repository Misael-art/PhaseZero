@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"

where pwsh.exe >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%bootstrap-ui.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%bootstrap-ui.ps1" %*
)
endlocal
