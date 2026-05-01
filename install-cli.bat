@echo off
setlocal enabledelayedexpansion

echo ======================================================
echo   Gemini CLI - Instalador Rapido (Modo Console)
echo ======================================================
echo.

:: Verifica se o bootstrap-tools.ps1 existe
if not exist "bootstrap-tools.ps1" (
    echo [ERRO] Arquivo bootstrap-tools.ps1 nao encontrado no diretorio atual.
    pause
    exit /b 1
)

:: Garante politica de execucao para a sessao
set "PS_CMD=powershell.exe -NoProfile -ExecutionPolicy Bypass"

echo [1/3] Carregando perfis disponiveis...
echo.

:: Lista perfis usando o proprio script
%PS_CMD% -Command "& { . .\bootstrap-tools.ps1 -BootstrapUiLibraryMode; Show-BootstrapProfiles }"

echo.
set /p PROFILE_CHOICE="Digite o nome do perfil que deseja instalar (ex: base, full, ai): "

if "%PROFILE_CHOICE%"=="" (
    echo [AVISO] Nenhum perfil selecionado. Saindo.
    pause
    exit /b 0
)

echo.
echo [2/3] Validando selecao: %PROFILE_CHOICE%
echo.

:: Executa um dry-run rapido para validar e mostrar o que sera feito
%PS_CMD% -File .\bootstrap-tools.ps1 -Profile %PROFILE_CHOICE% -DryRun -NonInteractive

echo.
set /p CONFIRM="Deseja prosseguir com a instalacao real? (S/N): "
if /i not "%CONFIRM%"=="S" (
    echo [AVISO] Instalacao cancelada pelo usuario.
    pause
    exit /b 0
)

echo.
echo [3/3] Iniciando instalacao do perfil: %PROFILE_CHOICE%
echo Isso pode levar varios minutos dependendo das dependencias...
echo.

:: Executa a instalacao real
%PS_CMD% -File .\bootstrap-tools.ps1 -Profile %PROFILE_CHOICE% -NonInteractive -SkipManualRequirements

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ======================================================
    echo   SUCESSO: Instalacao concluida!
    echo ======================================================
) else (
    echo.
    echo [ERRO] A instalacao falhou ou foi interrompida (ExitCode: %ERRORLEVEL%).
    echo Verifique o log gerado em seu diretorio TEMP.
)

echo.
pause
exit /b %ERRORLEVEL%
