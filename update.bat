@echo off
setlocal EnableExtensions
title MEC-AI Update

set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"

where git >nul 2>&1 || goto :git_error
where node >nul 2>&1 || goto :node_error
where npm >nul 2>&1 || goto :node_error

echo ============================================================
echo                    MEC-AI UPDATE
echo ============================================================
echo.
echo Repository: %ROOT%
echo.

git -C "%ROOT%" rev-parse --is-inside-work-tree >nul 2>&1 || goto :folder_error

for /f "delims=" %%A in ('git -C "%ROOT%" status --porcelain') do (
  echo Local changes detected. Update stopped to avoid overwriting them.
  echo Commit or stash your changes, then run update.bat again.
  pause
  exit /b 1
)

echo Pulling latest code from origin/main...
git -C "%ROOT%" pull --ff-only origin main
if errorlevel 1 goto :failed

echo.
echo Installing/updating npm dependencies...
call npm install --prefix "%ROOT%\apps\web"
if errorlevel 1 goto :failed

echo.
echo Update complete.
echo Run start-web.bat to launch the dashboard.
pause
exit /b 0

:git_error
echo Git is required. Install Git for Windows, then retry.
goto :stop

:node_error
echo Node.js is required. Install it from https://nodejs.org/
goto :stop

:folder_error
echo This file must be inside the MEC-AI repository.
goto :stop

:failed
echo Update failed. Check the error above.

:stop
pause
exit /b 1
