@echo off
setlocal
set "HOSTNAME=0.0.0.0"
set "PORT=3000"
cd /d "%~dp0"
call npm run dev
