@echo off
setlocal

set "ROOT=%~dp0"
set "API_DIR=%ROOT%services\api"
set "VENV=%API_DIR%\.venv"

py -3.12 --version >nul 2>&1
if errorlevel 1 (
  echo Python 3.12 is required. Install it from https://www.python.org/downloads/windows/
  pause
  exit /b 1
)

if not exist "%VENV%\Scripts\python.exe" (
  echo Installing MEC-AI API dependencies. This only happens once.
  py -3.12 -m venv "%VENV%"
  "%VENV%\Scripts\python.exe" -m pip install --upgrade pip
  "%VENV%\Scripts\python.exe" -m pip install -e "%API_DIR%"
  if errorlevel 1 (
    echo Installation failed. Check your internet connection, then run this file again.
    pause
    exit /b 1
  )
)

set "MECAI_ENABLE_MOCK_ENDPOINTS=false"
set "MECAI_DATABASE_PATH=%API_DIR%\.data\mecai.db"
echo MEC-AI API: http://127.0.0.1:8000
"%VENV%\Scripts\python.exe" -m uvicorn mecai_api.main:app --host 127.0.0.1 --port 8000
