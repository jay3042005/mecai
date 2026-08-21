@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -Command "$api = Start-Process 'api\MEC-AI-API.exe' -PassThru; $api.Id | Set-Content '.api.pid'; $env:HOSTNAME = '127.0.0.1'; $env:PORT = '3000'; $web = Start-Process 'web\node.exe' -ArgumentList 'web\server.js' -PassThru; $web.Id | Set-Content '.web.pid'"

powershell -NoProfile -Command "for ($i=0; $i -lt 30; $i++) { try { if ((Invoke-WebRequest http://127.0.0.1:3000/health -UseBasicParsing).StatusCode -eq 200) { Start-Process http://127.0.0.1:3000/dashboard; exit 0 } } catch {}; Start-Sleep -Seconds 1 }; Start-Process http://127.0.0.1:3000/dashboard"
