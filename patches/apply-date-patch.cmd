@echo off
rem One-click runner for patch_wcdb.ps1. Double-click this file to apply the patch.
rem
rem Extra arguments are forwarded to the PowerShell script, for example:
rem     apply-date-patch.cmd -Check
rem     apply-date-patch.cmd -Restore
rem     apply-date-patch.cmd -AppDir "<folder containing WeFlow.exe>"

setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch_wcdb.ps1" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
    echo Exit code 0 - all good.
) else (
    echo Exit code %RC% - see the messages above.
)
pause
exit /b %RC%
