@echo off
setlocal EnableExtensions
title MEC-AI Web Dashboard

set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "WEB=%ROOT%\apps\web"
set "PORT=3000"

echo ============================================================
echo                 MEC-AI WEB DASHBOARD
echo ============================================================
echo.
echo Detected folder: %ROOT%
echo.

if not exist "%ROOT%\pnpm-workspace.yaml" goto :folder_error
if not exist "%WEB%\package.json" goto :folder_error

where git >nul 2>&1 || goto :git_error
call corepack enable >nul 2>&1
where pnpm >nul 2>&1 || goto :pnpm_error

pushd "%ROOT%"
echo Installing dependencies...
call pnpm install
if errorlevel 1 goto :failed

set "LAN_IP="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /R /C:"IPv4 Address"') do if not defined LAN_IP set "LAN_IP=%%A"
set "LAN_IP=%LAN_IP: =%"
if not defined LAN_IP set "LAN_IP=127.0.0.1"

echo.
echo Local:   http://127.0.0.1:%PORT%/dashboard
echo Network: http://%LAN_IP%:%PORT%/dashboard
echo.
echo Starting server...
echo.

pushd "%WEB%"
set "HOSTNAME=0.0.0.0"
set "PORT=%PORT%"
start "MEC-AI Dashboard Server" /b cmd /c "set HOSTNAME=0.0.0.0&& set PORT=%PORT%&& cd /d "%WEB%" && pnpm run dev -- --hostname 0.0.0.0 --port %PORT% --allow-dev-origins *"
popd
popd

echo Waiting for server to be ready...
:wait_loop
timeout /t 1 /nobreak >nul
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:%PORT%/health' -TimeoutSec 1 -UseBasicParsing; exit 0 } catch { exit 1 }"
if errorlevel 1 goto :wait_loop

echo Server ready! Opening dashboard...
start "" "http://127.0.0.1:%PORT%/dashboard"

echo.
echo ============================================================
echo   Dashboard: http://127.0.0.1:%PORT%/dashboard
echo   Network:   http://%LAN_IP%:%PORT%/dashboard
echo ============================================================
echo.
echo Press any key to stop the server...
pause >nul
taskkill /FI "WINDOWTITLE eq MEC-AI Dashboard Server" /T /F >nul 2>&1
exit /b 0

:git_error
echo Git is required. Install Git for Windows, then retry.
goto :exit

:pnpm_error
echo pnpm is unavailable. Install Node.js/Corepack, then retry.
goto :exit

:failed
echo.
echo pnpm failed. Check the error above.
popd
goto :exit

:folder_error
echo Could not locate the MEC-AI folder.
echo Expected this file beside pnpm-workspace.yaml and apps\web\package.json.
echo.
echo Current path: %ROOT%
echo Checking files:
if exist "%ROOT%\pnpm-workspace.yaml" (echo   [OK] pnpm-workspace.yaml) else (echo   [MISSING] pnpm-workspace.yaml)
if exist "%WEB%\package.json" (echo   [OK] apps\web\package.json) else (echo   [MISSING] apps\web\package.json)

:exit
pause
exit /b 1
