@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "UI_SCRIPT=%SCRIPT_DIR%bootstrap-ui.ps1"
set "BACKEND_SCRIPT=%SCRIPT_DIR%bootstrap-tools.ps1"

set "PS_EXE="
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE set "PS_EXE=powershell.exe"

set "LOG_DIR="
call :resolve_log_dir
if not defined LOG_DIR set "LOG_DIR=%TEMP%\bootstrap-tools\logs"

set "TS="
for /f "delims=" %%I in ('%PS_EXE% -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss" 2^>nul') do set "TS=%%I"
if not defined TS set "TS=unknown"

set "LAUNCHER_LOG=%LOG_DIR%\bootstrap-ui_%TS%.launcher.log"
set "UI_LOG=%LOG_DIR%\bootstrap-ui_%TS%.ui.log"

call :log INFO "Bootstrap UI launcher started."
call :log INFO "SCRIPT_DIR=%SCRIPT_DIR%"
call :log INFO "PS_EXE=%PS_EXE%"
call :log INFO "LOG_DIR=%LOG_DIR%"
call :log INFO "UI_LOG=%UI_LOG%"

if not exist "%UI_SCRIPT%" (
  call :log ERROR "Arquivo nao encontrado: %UI_SCRIPT%"
  echo ERRO: %UI_SCRIPT% nao encontrado.
  exit /b 2
)
if not exist "%BACKEND_SCRIPT%" (
  call :log ERROR "Arquivo nao encontrado: %BACKEND_SCRIPT%"
  echo ERRO: %BACKEND_SCRIPT% nao encontrado.
  exit /b 2
)

set "IS_ADMIN=0"
for /f "delims=" %%A in ('whoami /groups 2^>nul ^| findstr /i /c:"S-1-5-32-544"') do set "IS_ADMIN=1"
if "%IS_ADMIN%"=="0" (
  net session >nul 2>&1 && set "IS_ADMIN=1"
)
set "BOOTSTRAP_IS_ADMIN=%IS_ADMIN%"
set "BOOTSTRAP_TOOLS_ROOT=%SCRIPT_DIR%"
set "BOOTSTRAP_TOOLS_LOG_DIR=%LOG_DIR%"
set "BOOTSTRAP_UI_LOG=%UI_LOG%"

call :log INFO "Admin=%IS_ADMIN%  ProcArch=%PROCESSOR_ARCHITECTURE%  Wow64=%PROCESSOR_ARCHITEW6432%  OS=%OS%"

pushd "%SCRIPT_DIR%" >nul 2>&1
if errorlevel 1 (
  call :log ERROR "Falha ao entrar no diretorio do script: %SCRIPT_DIR%"
  echo ERRO: falha ao acessar %SCRIPT_DIR%
  exit /b 3
)

call :log INFO "Launching UI: %UI_SCRIPT%"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%UI_SCRIPT%" -UiLogPath "%UI_LOG%" %*
set "EXITCODE=%ERRORLEVEL%"

call :log INFO "Bootstrap UI exited with code %EXITCODE%."
popd >nul 2>&1
exit /b %EXITCODE%

:log
set "LOG_LEVEL=%~1"
set "LOG_MSG=%~2"
set "LOG_LINE=[%DATE% %TIME%] [%LOG_LEVEL%] %LOG_MSG%"
if defined LAUNCHER_LOG call :append_log "%LAUNCHER_LOG%" "%LOG_LINE%"
echo %LOG_LINE%
exit /b 0

:append_log
set "APPEND_PATH=%~1"
set "APPEND_LINE=%~2"
if not defined APPEND_PATH exit /b 0
(>>"%APPEND_PATH%" echo %APPEND_LINE%) 2>nul
exit /b 0

:resolve_log_dir
if defined USERPROFILE call :probe_log_dir "%USERPROFILE%\.bootstrap-tools\logs"
if not defined LOG_DIR if defined LOCALAPPDATA call :probe_log_dir "%LOCALAPPDATA%\bootstrap-tools\logs"
if not defined LOG_DIR if defined TEMP call :probe_log_dir "%TEMP%\bootstrap-tools\logs"
if not defined LOG_DIR call :probe_log_dir "%SCRIPT_DIR%bootstrap-tools\logs"
exit /b 0

:probe_log_dir
if defined LOG_DIR exit /b 0
set "CANDIDATE_LOG_DIR=%~1"
if not defined CANDIDATE_LOG_DIR exit /b 0
if not exist "%CANDIDATE_LOG_DIR%" mkdir "%CANDIDATE_LOG_DIR%" >nul 2>&1
if not exist "%CANDIDATE_LOG_DIR%" exit /b 0
set "LOG_PROBE=%CANDIDATE_LOG_DIR%\bootstrap-ui-write-probe-%RANDOM%%RANDOM%.tmp"
(echo probe>"%LOG_PROBE%") >nul 2>&1
if exist "%LOG_PROBE%" (
  del /f /q "%LOG_PROBE%" >nul 2>&1
  set "LOG_DIR=%CANDIDATE_LOG_DIR%"
)
exit /b 0
