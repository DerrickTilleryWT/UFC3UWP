@echo off
rem Sends the latest build to the Xbox (only changed files) and starts it.
rem Run build-xbox.bat first. See deploy-xbox.ps1 for details.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-xbox.ps1" %*
echo.
pause
