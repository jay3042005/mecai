@echo off
setlocal

where winget >nul 2>&1
if errorlevel 1 (
  echo Windows Package Manager is required. Update or install App Installer from Microsoft Store.
  pause
  exit /b 1
)

echo Installing MEC-AI prerequisites. Accept each Windows prompt.
winget install --id Python.Python.3.12 --exact --accept-package-agreements --accept-source-agreements
if errorlevel 1 goto :failed

winget install --id OpenJS.NodeJS.LTS --exact --accept-package-agreements --accept-source-agreements
if errorlevel 1 goto :failed

winget install --id astral-sh.uv --exact --accept-package-agreements --accept-source-agreements
if errorlevel 1 goto :failed

echo.
echo Installation complete. Close this window, then double-click start-api.bat.
pause
exit /b 0

:failed
echo.
echo A prerequisite could not be installed. Check internet access, then run this file again.
pause
exit /b 1
