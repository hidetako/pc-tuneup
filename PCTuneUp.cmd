@echo off
rem PC TuneUp launcher. Double-click to open the GUI, or pass options for CLI use:
rem   PCTuneUp.cmd -Scan            scan only
rem   PCTuneUp.cmd -Scan -Fix -Auto scan and auto-fix low-risk issues
setlocal
set "SCRIPT=%~dp0PCTuneUp.ps1"
if "%~1"=="" (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT%"
) else (
    chcp 65001 >nul
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
    pause
)
endlocal
