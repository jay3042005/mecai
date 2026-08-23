@echo off
setlocal EnableExtensions
title MEC-AI API Server

set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "API_DIR=%ROOT%\services\api"
set "VENV=%API_DIR%\.venv"

echo ============================================================
echo                   MEC-AI API SERVER
echo ============================================================
echo.
echo Detected folder: %ROOT%
echo.

if not exist "%API_DIR%\pyproject.toml" goto :folder_error

py -3.12 --version >nul 2>&1 || goto :python_error

if not exist "%VENV%\Scripts\python.exe" (
  echo Installing MEC-AI API dependencies. This only happens once.
  py -3.12 -m venv "%VENV%"
  "%VENV%\Scripts\python.exe" -m pip install --upgrade pip
  "%VENV%\Scripts\python.exe" -m pip install -e "%API_DIR%"
  if errorlevel 1 goto :failed
)

set "LAN_IP="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /R /C:"IPv4 Address"') do if not defined LAN_IP set "LAN_IP=%%A"
set "LAN_IP=%LAN_IP: =%"
if not defined LAN_IP set "LAN_IP=127.0.0.1"

echo.
echo Local:   http://127.0.0.1:8000
echo Network: http://%LAN_IP%:8000
echo.
echo Starting server...
echo Keep this window open.
echo.

set "MECAI_ENABLE_MOCK_ENDPOINTS=false"
set "MECAI_DATABASE_PATH=%API_DIR%\.data\mecai.db"
rem The mDNS advertisement must name the same port uvicorn binds.
set "MECAI_PORT=8000"
"%VENV%\Scripts\python.exe" -m uvicorn mecai_api.main:app --host 0.0.0.0 --port 8000
exit /b 0

:python_error
echo Python 3.12 is required. Install it from https://www.python.org/downloads/windows/
goto :exit

:failed
echo.
echo Installation failed. Check the error above.

:exit
pause
exit /b 1

:folder_error
echo Could not locate the MEC-AI API folder.
echo Expected this file beside pnpm-workspace.yaml and services\api\pyproject.toml.
echo.
echo Current path: %ROOT%
echo Checking files:
if exist "%ROOT%\pnpm-workspace.yaml" (echo   [OK] pnpm-workspace.yaml) else (echo   [MISSING] pnpm-workspace.yaml)
if exist "%API_DIR%\pyproject.toml" (echo   [OK] services\api\pyproject.toml) else (echo   [MISSING] services\api\pyproject.toml)
goto :exit
