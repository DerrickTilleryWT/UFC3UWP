@echo off
rem Downloads log.txt from the app on the Xbox to xbox-log.txt in this folder.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-xbox.ps1" -GetLog
echo.
pause
