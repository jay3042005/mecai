@echo off
:: Double-click this — opens the MEC-AI Launcher GUI with no terminal.
:: It auto-detects the MECAI folder even if you moved the whole folder to Desktop.
setlocal
set "HERE=%~dp0"
if exist "%HERE%MECAI-Launcher.exe" start "" "%HERE%MECAI-Launcher.exe" & exit /b 0
if exist "%HERE%dist\MECAI-Launcher.exe" start "" "%HERE%dist\MECAI-Launcher.exe" & exit /b 0
if exist "%HERE%deploy\launcher\dist\MECAI-Launcher.exe" start "" "%HERE%deploy\launcher\dist\MECAI-Launcher.exe" & exit /b 0
:: fallback: run via Python (dev) hidden-ish
where py >nul 2>&1
if not errorlevel 1 start "" /min py -3 "%HERE%deploy\launcher\mecai_launcher.py" & exit /b 0
where python >nul 2>&1
if not errorlevel 1 start "" /min python "%HERE%deploy\launcher\mecai_launcher.py" & exit /b 0
echo Could not find MECAI-Launcher.exe and no Python found.
echo Build it with deploy\launcher\build.bat or install Python 3.12 from https://www.python.org/downloads/windows/
pause
exit /b 1
