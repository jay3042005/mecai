@echo off
powershell -NoProfile -Command "foreach ($file in '.api.pid','.web.pid') { if (Test-Path $file) { Stop-Process -Id (Get-Content $file) -Force -ErrorAction SilentlyContinue; Remove-Item $file -Force } }"
