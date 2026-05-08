@echo off
:: PhaseZero Bootstrap - launcher CLI
:: Redireciona para o script PowerShell principal e propaga argumentos
:: Exemplos:
::   install-cli.bat
::   install-cli.bat -Profile base -NonInteractive
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-cli.ps1" %*
exit /b %ERRORLEVEL%
