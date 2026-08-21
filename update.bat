@echo off
setlocal EnableExtensions
title MEC-AI Update

set "ROOT=%~dp0"
pushd "%ROOT%" || goto :folder_error

where git >nul 2>&1 || goto :git_error
where pnpm >nul 2>&1 || (
  call corepack enable >nul 2>&1
  where pnpm >nul 2>&1 || goto :pnpm_error
)

echo ============================================================
echo                    MEC-AI UPDATE
echo ============================================================
echo.

git rev-parse --is-inside-work-tree >nul 2>&1 || goto :folder_error

for /f "delims=" %%A in ('git status --porcelain') do (
  echo Local changes detected. Update stopped to avoid overwriting them.
  echo Commit or stash your changes, then run update.bat again.
  popd
  pause
  exit /b 1
)

echo Pulling latest code from origin/main...
git pull --ff-only origin main
if errorlevel 1 goto :failed

echo.
echo Installing/updating pnpm dependencies...
call pnpm install
if errorlevel 1 goto :failed

echo.
echo Update complete.
echo Run start-web.bat to launch the dashboard.
popd
pause
exit /b 0

:git_error
echo Git is required. Install Git for Windows, then retry.
goto :stop

:pnpm_error
echo pnpm is unavailable. Install Node.js/Corepack, then retry.
goto :stop

:folder_error
echo This file must be inside the MEC-AI repository.
goto :stop

:failed
echo Update failed. Check the error above.

:stop
popd
pause
exit /b 1
