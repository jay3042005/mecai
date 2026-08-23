@echo off
setlocal EnableExtensions
title Build MEC-AI Launcher

set "ROOT=%~dp0..\.."
pushd "%~dp0"

where py >nul 2>&1 || goto :no_py
py -3 --version >nul 2>&1 || goto :no_py

echo Installing PyInstaller if needed...
py -3 -m pip install --upgrade pyinstaller >nul 2>&1

echo Building MECAI-Launcher.exe (no console)...
:: Icon: a real multi-size .ico is committed at deploy\launcher\icon.ico.
:: PyInstaller on Windows rejects PNG icons unless Pillow is installed, which
:: is why this once failed on machines without it — the committed .ico removes
:: that dependency entirely.
set "ICON="
if exist "%~dp0icon.ico" set "ICON=--icon=%~dp0icon.ico"

py -3 -m PyInstaller --noconfirm --onefile --noconsole --name MECAI-Launcher --clean mecai_launcher.py %ICON%

if errorlevel 1 goto :failed

echo.
echo Built: %~dp0dist\MECAI-Launcher.exe
echo Copy to repo root for testing:
copy /Y "%~dp0dist\MECAI-Launcher.exe" "%ROOT%\MECAI-Launcher.exe"
echo Done. Double-click MECAI-Launcher.exe — no terminal needed.
popd
pause
exit /b 0

:no_py
echo Python 3.12+ (py launcher) not found. Install from https://www.python.org/downloads/windows/
pause
exit /b 1

:failed
echo Build failed. Check errors above.
popd
pause
exit /b 1
