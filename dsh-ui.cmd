@echo off
rem dsh-ui (Windows) launcher.
rem NOTE: keep this file pure ASCII. cmd.exe parses .cmd files with the OEM code
rem page, so UTF-8 Chinese comments here corrupt the batch file and cmd starts
rem executing comment fragments as commands (hit during verification).
rem Prefers Windows PowerShell 5.1: measured ~2x faster than PowerShell 7 for
rem this tool (in-process WinRT OCR, faster startup).
setlocal
set "SCRIPT=%~dp0dsh-ui.ps1"
if not exist "%SCRIPT%" (
  echo dsh-ui: script not found: "%SCRIPT%" 1>&2
  exit /b 2
)
set "PSHOST=powershell.exe"
where powershell.exe >nul 2>nul
if errorlevel 1 (
  where pwsh.exe >nul 2>nul
  if errorlevel 1 (
    echo dsh-ui: neither powershell.exe nor pwsh.exe found 1>&2
    exit /b 2
  )
  set "PSHOST=pwsh.exe"
)
"%PSHOST%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
