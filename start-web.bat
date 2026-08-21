@echo off
setlocal EnableExtensions
title MEC-AI

set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "WEB=%ROOT%\apps\web"
set "API_DIR=%ROOT%\services\api"
set "VENV=%API_DIR%\.venv"
set "WEB_PORT=3000"
set "API_PORT=8000"

echo ============================================================
echo                      MEC-AI
echo ============================================================
echo.
echo Detected folder: %ROOT%
echo.

if not exist "%ROOT%\pnpm-workspace.yaml" goto :folder_error
if not exist "%WEB%\package.json" goto :folder_error
if not exist "%API_DIR%\pyproject.toml" goto :folder_error

py -3.12 --version >nul 2>&1 || goto :python_error
call corepack enable >nul 2>&1
where pnpm >nul 2>&1 || goto :pnpm_error

set "LAN_IP="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /R /C:"IPv4 Address"') do if not defined LAN_IP set "LAN_IP=%%A"
set "LAN_IP=%LAN_IP: =%"
if not defined LAN_IP set "LAN_IP=127.0.0.1"

pushd "%ROOT%"
echo Installing dashboard dependencies...
call pnpm install
if errorlevel 1 goto :failed

if not exist "%VENV%\Scripts\python.exe" (
  echo Installing API dependencies...
  py -3.12 -m venv "%VENV%"
  "%VENV%\Scripts\python.exe" -m pip install --upgrade pip
  "%VENV%\Scripts\python.exe" -m pip install -e "%API_DIR%"
  if errorlevel 1 goto :failed
)
popd

echo.
echo Starting API server...
start "MEC-AI API Server" /b "%ROOT%\start-api-server.bat"

echo Starting dashboard...
start "MEC-AI Dashboard Server" /b "%ROOT%\start-dashboard.bat"

echo Waiting for servers to be ready...
:wait_api
timeout /t 1 /nobreak >nul
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:%API_PORT%/' -TimeoutSec 1 -UseBasicParsing; exit 0 } catch { exit 1 }"
if errorlevel 1 goto :wait_api

:wait_web
timeout /t 1 /nobreak >nul
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:%WEB_PORT%/health' -TimeoutSec 1 -UseBasicParsing; exit 0 } catch { exit 1 }"
if errorlevel 1 goto :wait_web

echo.
echo Opening dashboard...
start "" "http://127.0.0.1:%WEB_PORT%/dashboard"

echo.
echo ============================================================
echo   Dashboard: http://127.0.0.1:%WEB_PORT%/dashboard
echo   API:       http://127.0.0.1:%API_PORT%
echo.
echo   LAN Dashboard: http://%LAN_IP%:%WEB_PORT%/dashboard
echo   LAN API:       http://%LAN_IP%:%API_PORT%
echo ============================================================
echo.
echo Press any key to stop both servers...
pause >nul
taskkill /FI "WINDOWTITLE eq MEC-AI Dashboard Server" /T /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq MEC-AI API Server" /T /F >nul 2>&1
exit /b 0

:python_error
echo Python 3.12 is required. Install it from https://www.python.org/downloads/windows/
goto :exit

:pnpm_error
echo pnpm is unavailable. Install Node.js/Corepack, then retry.
goto :exit

:failed
echo.
echo Setup failed. Check the error above.
popd
goto :exit

:folder_error
echo Could not locate the MEC-AI folder.
echo Expected this file beside pnpm-workspace.yaml.
echo.
echo Current path: %ROOT%
echo Checking files:
if exist "%ROOT%\pnpm-workspace.yaml" (echo   [OK] pnpm-workspace.yaml) else (echo   [MISSING] pnpm-workspace.yaml)
if exist "%WEB%\package.json" (echo   [OK] apps\web\package.json) else (echo   [MISSING] apps\web\package.json)
if exist "%API_DIR%\pyproject.toml" (echo   [OK] services\api\pyproject.toml) else (echo   [MISSING] services\api\pyproject.toml)

:exit
pause
exit /b 1
