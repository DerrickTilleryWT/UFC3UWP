@echo off
rem Extra settings for the game on the Xbox, for when something goes wrong
rem (clear the shader cache, undo in-game menu changes). No rebuild needed.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-xbox.ps1" -Options
echo.
pause
