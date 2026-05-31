@echo off
setlocal EnableExtensions DisableDelayedExpansion
:: PhaseZero Bootstrap - launcher CLI
:: Redireciona para o script PowerShell principal e propaga argumentos
:: Exemplos:
::   install-cli.bat
::   install-cli.bat -Profile base -NonInteractive
::   install-cli.bat --tool claude-code --validate --dry-run --yes

set "SCRIPT_DIR=%~dp0"
set "BOOTSTRAP_CLI_VERBOSE=0"
set "PS_EXE="
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE set "PS_EXE=powershell.exe"

if not exist "%PS_EXE%" (
  call :error "Windows PowerShell 5.1 nao encontrado: %PS_EXE%"
  exit /b 1
)
if not exist "%SCRIPT_DIR%install-cli.ps1" (
  call :error "install-cli.ps1 nao encontrado em %SCRIPT_DIR%"
  exit /b 1
)

pushd "%SCRIPT_DIR%" >nul 2>nul
if errorlevel 1 (
  call :error "Falha ao entrar em %SCRIPT_DIR%"
  exit /b 1
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install-cli.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
popd >nul 2>nul
endlocal & exit /b %EXIT_CODE%

:error
setlocal EnableDelayedExpansion
set "ERR_MSG=%~1"
if /I "%BOOTSTRAP_CLI_VERBOSE%"=="1" (
  echo install-cli: !ERR_MSG! 1>&2
) else (
  echo !ERR_MSG! 1>&2
)
endlocal
exit /b 0
