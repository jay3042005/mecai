@echo off
setlocal
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "API_DIR=%ROOT%\services\api"
set "VENV=%API_DIR%\.venv"
set "MECAI_ENABLE_MOCK_ENDPOINTS=false"
set "MECAI_DATABASE_PATH=%API_DIR%\.data\mecai.db"
cd /d "%API_DIR%"
"%VENV%\Scripts\python.exe" -m uvicorn mecai_api.main:app --host 0.0.0.0 --port 8000
