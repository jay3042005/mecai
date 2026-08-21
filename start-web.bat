@echo off
setlocal

set "ROOT=%~dp0"
set "WEB=%ROOT%apps\web"

where node >nul 2>&1
if errorlevel 1 (
  echo Node.js is required. Run setup-windows.bat first.
  pause
  exit /b 1
)

call corepack enable >nul 2>&1

if not exist "%ROOT%node_modules" (
  echo Installing dashboard dependencies. This only happens once.
  call pnpm install --dir "%ROOT%"
  if errorlevel 1 goto :failed
)

if not exist "%WEB%\.next\BUILD_ID" (
  echo Building the dashboard. This only happens once per code change.
  call pnpm --dir "%WEB%" build
  if errorlevel 1 goto :failed
)

echo MEC-AI dashboard: http://127.0.0.1:3000
if not exist "%WEB%\.next\standalone\server.js" goto :failed

rem Standalone output does not support `next start`.
if not exist "%WEB%\.next\standalone\.next\static" mkdir "%WEB%\.next\standalone\.next\static"
xcopy /E /I /Y "%WEB%\.next\static" "%WEB%\.next\standalone\.next\static" >nul
if exist "%WEB%\public" (
  xcopy /E /I /Y "%WEB%\public" "%WEB%\.next\standalone\public" >nul
)

set "PORT=3000"
call node "%WEB%\.next\standalone\server.js"
if errorlevel 1 goto :failed
exit /b 0

:failed
echo.
echo The dashboard could not start. Check the messages above, then run this file again.
pause
exit /b 1
