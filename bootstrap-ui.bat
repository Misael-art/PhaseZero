@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "UI_SCRIPT=%SCRIPT_DIR%bootstrap-ui.ps1"
set "BACKEND_SCRIPT=%SCRIPT_DIR%bootstrap-tools.ps1"
set "BOOTSTRAP_SMOKE_TEST=0"
set "BOOTSTRAP_UI_SHORTCUT="
set "BOOTSTRAP_UI_FORWARD_ARGS="
for %%A in (%*) do (
  if /I "%%~A"=="-SmokeTest" set "BOOTSTRAP_SMOKE_TEST=1"
  if /I "%%~A"=="-SmokeTestWindow" set "BOOTSTRAP_SMOKE_TEST=1"
  if /I "%%~A"=="--smoke" set "BOOTSTRAP_SMOKE_TEST=1"
  if /I "%%~A"=="--verbose" set "BOOTSTRAP_UI_VERBOSE=1"
  if /I "%%~A"=="--doctor" set "BOOTSTRAP_UI_SHORTCUT=doctor"
  if /I "%%~A"=="--support-bundle" set "BOOTSTRAP_UI_SHORTCUT=support-bundle"
  if /I "%%~A"=="--repair-plan" set "BOOTSTRAP_UI_SHORTCUT=repair-plan"
)

set "PS_EXE="
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE set "PS_EXE=powershell.exe"

set "LOG_DIR="
call :resolve_log_dir

set "TS="
call :resolve_timestamp

set "LAUNCHER_LOG="
set "UI_LOG="
if defined LOG_DIR (
  set "LAUNCHER_LOG=%LOG_DIR%\bootstrap-ui_%TS%.launcher.log"
  set "UI_LOG=%LOG_DIR%\bootstrap-ui_%TS%.ui.log"
)

call :log INFO "Bootstrap UI launcher started."
call :log INFO "SCRIPT_DIR=%SCRIPT_DIR%"
call :log INFO "PS_EXE=%PS_EXE%"
call :log INFO "LOG_DIR=%LOG_DIR%"
call :log INFO "UI_LOG=%UI_LOG%"
call :log INFO "SHORTCUT=%BOOTSTRAP_UI_SHORTCUT%"

if not exist "%UI_SCRIPT%" (
  call :log ERROR "Arquivo nao encontrado: %UI_SCRIPT%"
  if "%BOOTSTRAP_SMOKE_TEST%"=="1" (
    >&2 echo(ERRO: %UI_SCRIPT% nao encontrado.
  ) else (
    echo(ERRO: %UI_SCRIPT% nao encontrado.
    call :print_preflight
  )
  exit /b 2
)
if not exist "%BACKEND_SCRIPT%" (
  call :log ERROR "Arquivo nao encontrado: %BACKEND_SCRIPT%"
  if "%BOOTSTRAP_SMOKE_TEST%"=="1" (
    >&2 echo(ERRO: %BACKEND_SCRIPT% nao encontrado.
  ) else (
    echo(ERRO: %BACKEND_SCRIPT% nao encontrado.
    call :print_preflight
  )
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
  if "%BOOTSTRAP_SMOKE_TEST%"=="1" (
    >&2 echo(ERRO: falha ao acessar %SCRIPT_DIR%
  ) else (
    echo(ERRO: falha ao acessar %SCRIPT_DIR%
    call :print_preflight
  )
  exit /b 3
)

if defined BOOTSTRAP_UI_SHORTCUT goto :run_shortcut

call :log INFO "Launching UI: %UI_SCRIPT%"
if "%BOOTSTRAP_SMOKE_TEST%"=="1" (
  if defined UI_LOG (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%UI_SCRIPT%" -UiLogPath "%UI_LOG%" %*
  ) else (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%UI_SCRIPT%" %*
  )
) else (
  echo(PhaseZero UI iniciando...
  if defined UI_LOG (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%UI_SCRIPT%" -UiLogPath "%UI_LOG%" %*
  ) else (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%UI_SCRIPT%" %*
  )
)
set "EXITCODE=%ERRORLEVEL%"

call :log INFO "Bootstrap UI exited with code %EXITCODE%."
if not "%BOOTSTRAP_SMOKE_TEST%"=="1" if not "%EXITCODE%"=="0" call :print_failure
popd >nul 2>&1
exit /b %EXITCODE%

:run_shortcut
call :log INFO ("Atalho ativo: %BOOTSTRAP_UI_SHORTCUT%")
set "SHORTCUT_FLAG="
if /I "%BOOTSTRAP_UI_SHORTCUT%"=="doctor" set "SHORTCUT_FLAG=-Doctor"
if /I "%BOOTSTRAP_UI_SHORTCUT%"=="support-bundle" set "SHORTCUT_FLAG=-SupportBundle"
if /I "%BOOTSTRAP_UI_SHORTCUT%"=="repair-plan" set "SHORTCUT_FLAG=-RepairPlan"
if not defined SHORTCUT_FLAG (
  echo(ERRO: atalho desconhecido: %BOOTSTRAP_UI_SHORTCUT%
  call :print_preflight
  popd >nul 2>&1
  exit /b 4
)
echo(PhaseZero atalho %BOOTSTRAP_UI_SHORTCUT% (dry-run, sem alteracoes)...
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%BACKEND_SCRIPT%" %SHORTCUT_FLAG% -DryRun -NonInteractive
set "EXITCODE=%ERRORLEVEL%"
call :log INFO "Atalho %BOOTSTRAP_UI_SHORTCUT% terminou com codigo %EXITCODE%."
if not "%EXITCODE%"=="0" call :print_failure
popd >nul 2>&1
exit /b %EXITCODE%

:log
setlocal EnableDelayedExpansion
set "LOG_LEVEL=%~1"
set "LOG_MSG=%~2"
set "LOG_LINE=[%DATE% %TIME%] [%LOG_LEVEL%] %LOG_MSG%"
if defined LAUNCHER_LOG call :append_log "!LAUNCHER_LOG!" "!LOG_LINE!"
if not "%BOOTSTRAP_SMOKE_TEST%"=="1" if /I "%BOOTSTRAP_UI_VERBOSE%"=="1" echo(!LOG_LINE!
endlocal
exit /b 0

:print_preflight
echo(
echo(Preflight (diagnostico):
echo(  PowerShell: %PS_EXE%
echo(  UI script:  %UI_SCRIPT%
echo(  Backend:    %BACKEND_SCRIPT%
echo(  Diretorio:  %SCRIPT_DIR%
echo(  Admin:      %IS_ADMIN%
echo(  Log dir:    %LOG_DIR%
exit /b 0

:print_failure
echo(
echo(PhaseZero UI falhou. Codigo: %EXITCODE%
if defined UI_LOG echo(Log UI:        %UI_LOG%
if defined LAUNCHER_LOG echo(Log launcher:  %LAUNCHER_LOG%
echo(
echo(Diagnostico rapido:
echo(  Smoke contrato:   bootstrap-ui.bat -SmokeTest
echo(  Smoke window:     bootstrap-ui.bat -SmokeTestWindow
echo(  Doctor dry-run:   bootstrap-ui.bat --doctor
echo(  Support bundle:   bootstrap-ui.bat --support-bundle
echo(  Repair plan:      bootstrap-ui.bat --repair-plan
echo(  Verbose launcher: set BOOTSTRAP_UI_VERBOSE=1 ^&^& bootstrap-ui.bat
exit /b 0

:append_log
setlocal EnableDelayedExpansion
set "APPEND_PATH=%~1"
set "APPEND_LINE=%~2"
if not defined APPEND_PATH (
  endlocal
  exit /b 0
)
(>>"!APPEND_PATH!" echo(!APPEND_LINE!) 2>nul
endlocal
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

:resolve_timestamp
for /f "delims=" %%I in ('"%PS_EXE%" -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss" 2^>nul') do if not defined TS set "TS=%%I"
if defined TS exit /b 0
set "TS=%DATE%_%TIME%"
set "TS=%TS:/=-%"
set "TS=%TS:\=-%"
set "TS=%TS::=-%"
set "TS=%TS:.=-%"
set "TS=%TS:,=-%"
set "TS=%TS: =_%"
if not defined TS set "TS=%RANDOM%%RANDOM%"
exit /b 0
