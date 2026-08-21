@echo off
setlocal
set "HOSTNAME=0.0.0.0"
set "PORT=3000"
cd /d "%~dp0apps\web"
npx next dev --hostname 0.0.0.0 --port 3000
