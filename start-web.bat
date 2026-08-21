@echo off
setlocal EnableExtensions
title MEC-AI Web Dashboard

set "ROOT=%~dp0"
set "WEB=%ROOT%apps\web"
set "PORT=3000"

if not exist "%ROOT%package.json" goto :folder_error
if not exist "%WEB%\package.json" goto :folder_error
pushd "%ROOT%" || goto :folder_error

cls
echo ============================================================
echo                 MEC-AI WEB DASHBOARD
echo ============================================================
echo.

where node >nul 2>&1 || goto :node_error
where pnpm >nul 2>&1 || (
  call corepack enable >nul 2>&1
  where pnpm >nul 2>&1 || goto :pnpm_error
)

rem Select the first non-loopback IPv4 address for phone/LAN access.
set "LAN_IP="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /R /C:"IPv4 Address"') do if not defined LAN_IP set "LAN_IP=%%A"
set "LAN_IP=%LAN_IP: =%"
if not defined LAN_IP set "LAN_IP=127.0.0.1"

if not exist "%ROOT%node_modules" (
  echo [1/3] Installing dashboard dependencies...
  call pnpm install
  if errorlevel 1 goto :failed
)

if not exist "%WEB%\.next\BUILD_ID" (
  echo [2/3] Building dashboard...
  pushd "apps\web"
  call pnpm build
  popd
  if errorlevel 1 goto :failed
)

if not exist "%WEB%\.next\standalone\server.js" (
  echo Standalone server missing. Rebuilding...
  pushd "apps\web"
  call pnpm build
  popd
  if errorlevel 1 goto :failed
)

rem Standalone output needs these runtime assets copied beside server.js.
if not exist "%WEB%\.next\standalone\.next\static" mkdir "%WEB%\.next\standalone\.next\static"
xcopy /E /I /Y "%WEB%\.next\static" "%WEB%\.next\standalone\.next\static" >nul
if exist "%WEB%\public" xcopy /E /I /Y "%WEB%\public" "%WEB%\.next\standalone\public" >nul

echo.
echo [3/3] Starting dashboard...
echo.
echo   Local:   http://127.0.0.1:%PORT%
echo   Network: http://%LAN_IP%:%PORT%
echo.
echo Opening the dashboard in your browser...

rem Bind all interfaces so another phone on the same LAN can connect.
set "HOSTNAME=0.0.0.0"
start "MEC-AI Dashboard Server" /b node "%WEB%\.next\standalone\server.js"
timeout /t 3 /nobreak >nul
start "" "http://127.0.0.1:%PORT%/dashboard"

echo Dashboard is running. Keep this window open.
echo Close this window to stop the dashboard.
echo.
pause
taskkill /FI "WINDOWTITLE eq MEC-AI Dashboard Server" /T /F >nul 2>&1
popd
exit /b 0

:node_error
echo Node.js is required. Run setup-windows.bat first.
pause
exit /b 1

:pnpm_error
echo pnpm is unavailable. Run setup-windows.bat first.
pause
exit /b 1

:failed
echo.
echo Dashboard setup failed. Check the error above, then run this file again.
popd
pause
exit /b 1

:folder_error
echo Could not locate the MEC-AI folder.
echo Expected this file beside package.json and apps\web\package.json.
echo Current launcher path: %~dp0
pause
exit /b 1
