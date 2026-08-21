@echo off
title MEC-AI

echo Starting MEC-AI...
echo.

start "MEC-AI API" /min "%~dp0start-api.bat"
start "MEC-AI Dashboard" /min "%~dp0apps\web\dev.bat"

timeout /t 5 /nobreak >nul

echo ============================================================
echo   Dashboard: http://localhost:3000/dashboard
echo   API:       http://localhost:8000
echo ============================================================
echo.
echo Press any key to stop...
pause >nul
taskkill /FI "WINDOWTITLE eq MEC-AI API" /T /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq MEC-AI Dashboard" /T /F >nul 2>&1
