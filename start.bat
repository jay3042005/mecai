@echo off
title MEC-AI

set "LAN_IP="
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /R /C:"IPv4 Address"') do if not defined LAN_IP set "LAN_IP=%%A"
set "LAN_IP=%LAN_IP: =%"
if not defined LAN_IP set "LAN_IP=127.0.0.1"

echo Starting MEC-AI...
echo.

start "MEC-AI API" /min "%~dp0start-api.bat"
start "MEC-AI Dashboard" /min "%~dp0apps\web\dev.bat"

echo Waiting for servers...
:wait
timeout /t 2 /nobreak >nul
powershell -NoProfile -Command "$c=[Net.Sockets.TcpClient]::new();try{$c.Connect('127.0.0.1',3000);$c.Close();exit 0}catch{exit 1}"
if errorlevel 1 goto :wait

start "" "http://localhost:3000/dashboard"

echo.
echo ============================================================
echo   Dashboard: http://localhost:3000/dashboard
echo   API:       http://localhost:8000
echo.
echo   LAN Dashboard: http://%LAN_IP%:3000/dashboard
echo   LAN API:       http://%LAN_IP%:8000
echo ============================================================
echo.
echo Press any key to stop...
pause >nul
taskkill /FI "WINDOWTITLE eq MEC-AI API" /T /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq MEC-AI Dashboard" /T /F >nul 2>&1
