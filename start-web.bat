@echo off
setlocal EnableExtensions
title MEC-AI

set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "WEB=%ROOT%\apps\web"
set "API_DIR=%ROOT%\services\api"
set "VENV=%API_DIR%\.venv"

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
where node >nul 2>&1 || goto :node_error
where npm >nul 2>&1 || goto :node_error

set "LAN_IP="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /R /C:"IPv4 Address"') do if not defined LAN_IP set "LAN_IP=%%A"
set "LAN_IP=%LAN_IP: =%"
if not defined LAN_IP set "LAN_IP=127.0.0.1"

pushd "%ROOT%"
echo Installing dashboard dependencies...
call npm install --prefix "%WEB%"
if errorlevel 1 goto :failed
popd

if not exist "%VENV%\Scripts\python.exe" (
  echo Installing API dependencies...
  py -3.12 -m venv "%VENV%"
  "%VENV%\Scripts\python.exe" -m pip install --upgrade pip
  "%VENV%\Scripts\python.exe" -m pip install -e "%API_DIR%"
  if errorlevel 1 goto :failed
)

echo.
echo Starting API server...
set "MECAI_ENABLE_MOCK_ENDPOINTS=false"
set "MECAI_DATABASE_PATH=%API_DIR%\.data\mecai.db"
start "MEC-AI API" /min "%VENV%\Scripts\python.exe" -m uvicorn mecai_api.main:app --host 0.0.0.0 --port 8000

echo Starting dashboard...
start "MEC-AI Dashboard" /min "%WEB%\dev.bat"

echo Waiting for servers to be ready...
:wait_api
timeout /t 1 /nobreak >nul
powershell -NoProfile -Command "$c=[Net.Sockets.TcpClient]::new();try{$c.Connect('127.0.0.1',8000);$c.Close();exit 0}catch{exit 1}"
if errorlevel 1 goto :wait_api

:wait_web
timeout /t 1 /nobreak >nul
powershell -NoProfile -Command "$c=[Net.Sockets.TcpClient]::new();try{$c.Connect('127.0.0.1',3000);$c.Close();exit 0}catch{exit 1}"
if errorlevel 1 goto :wait_web

echo.
echo Opening dashboard...
start "" "http://127.0.0.1:3000/dashboard"

echo.
echo ============================================================
echo   Dashboard: http://127.0.0.1:3000/dashboard
echo   API:       http://127.0.0.1:8000
echo.
echo   LAN Dashboard: http://%LAN_IP%:3000/dashboard
echo   LAN API:       http://%LAN_IP%:8000
echo ============================================================
echo.
echo Press any key to stop both servers...
pause >nul
taskkill /FI "WINDOWTITLE eq MEC-AI API" /T /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq MEC-AI Dashboard" /T /F >nul 2>&1
exit /b 0

:python_error
echo Python 3.12 is required. Install it from https://www.python.org/downloads/windows/
goto :exit

:node_error
echo Node.js is required. Install it from https://nodejs.org/
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
