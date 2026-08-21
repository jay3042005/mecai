@echo off
setlocal
cd /d "%~dp0apps\web"
set "HOSTNAME=0.0.0.0"
set "PORT=3000"
call pnpm run dev -- --hostname 0.0.0.0 --port 3000 --allow-dev-origins *
