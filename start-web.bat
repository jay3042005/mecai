@echo off
setlocal EnableExtensions
title MEC-AI Web Dashboard

set "ROOT=%~dp0"
set "WEB=%ROOT%apps\web"
set "PORT=3000"

if not exist "%ROOT%package.json" goto :folder_error
if not exist "%WEB%\package.json" goto :folder_error

pushd "%ROOT%" || goto :folder_error
call corepack enable >nul 2>&1
where pnpm >nul 2>&1 || goto :pnpm_error

cls
echo ============================================================
echo                 MEC-AI WEB DASHBOARD
echo ============================================================
echo.
echo Installing dependencies with pnpm...
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
echo Starting with pnpm dev...
echo Keep this window open.
echo.

start "MEC-AI Dashboard Server" /b pnpm --dir apps/web run dev -- --hostname 0.0.0.0 --port %PORT%
timeout /t 3 /nobreak >nul
start "" "http://127.0.0.1:%PORT%/dashboard"
echo Server running. Press Ctrl+C here to stop it.
pause
taskkill /FI "WINDOWTITLE eq MEC-AI Dashboard Server" /T /F >nul 2>&1
popd
exit /b 0

:pnpm_error
echo pnpm is unavailable. Install Node.js/Corepack, then retry.
popd
pause
exit /b 1

:failed
echo.
echo pnpm failed. Check the error above.
popd
pause
exit /b 1

:folder_error
echo Could not locate the MEC-AI folder.
echo Expected this file beside package.json and apps\web\package.json.
echo Launcher path: %~dp0
pause
exit /b 1
