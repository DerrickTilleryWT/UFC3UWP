@echo off
rem ==========================================================================
rem  install-tools.bat - installs what the build needs, once:
rem    Git, and Visual Studio 2022 Community with the C++, Clang and UWP
rem    (Xbox app) tools listed in .vsconfig next to this script.
rem  If Visual Studio 2022 is already installed, the missing parts are added
rem  to it instead. Windows asks for permission (a UAC prompt) - say yes.
rem ==========================================================================
setlocal EnableExtensions
cd /d "%~dp0"
title Installing the build tools
echo.
echo  Installing the build tools (Git and Visual Studio 2022 with C++ and UWP)
echo  =======================================================================
echo  This downloads several GB and can take 30 minutes or more.
echo.
where winget >nul 2>nul
if errorlevel 1 goto :no_winget

where git >nul 2>nul
if not errorlevel 1 goto :git_done
echo  Installing Git...
winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
if errorlevel 1 goto :failed
:git_done
echo  Git: OK

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSDIR="
if exist "%VSWHERE%" for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -version [17.0^,18.0^) -products * -property installationPath`) do set "VSDIR=%%i"
if defined VSDIR goto :vs_modify

echo  Installing Visual Studio 2022 Community with the needed parts...
winget install --id Microsoft.VisualStudio.2022.Community -e --source winget --accept-package-agreements --accept-source-agreements --override "--wait --passive --norestart --config \"%~dp0.vsconfig\""
goto :check

:vs_modify
echo  Visual Studio found: %VSDIR%
echo  Adding any missing parts (C++, Clang, UWP tools)...
"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\setup.exe" modify --installPath "%VSDIR%" --config "%~dp0.vsconfig" --passive --norestart

:check
rem The installers' exit codes also say "restart needed", so check the
rem result itself: a Visual Studio 2022 with the C++ and UWP tools.
set "VSOK="
if exist "%VSWHERE%" for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -version [17.0^,18.0^) -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.ComponentGroup.UWP.VC -property installationPath`) do set "VSOK=%%i"
if not defined VSOK goto :failed

echo.
echo  ==========================================================
echo   DONE. The build tools are installed.
echo  ==========================================================
echo  Restart your PC once, then run build-xbox.bat.
echo.
pause
exit /b 0

:no_winget
echo  winget (App Installer) isn't on this PC. Install the tools by hand as
echo  the README says, or get "App Installer" from the Microsoft Store and
echo  run this again.
echo.
pause
exit /b 1

:failed
echo.
echo  Installing failed (see the messages above). You can install the tools
echo  by hand as the README says: in the Visual Studio Installer, choose
echo  More, Import configuration, and pick the .vsconfig file in this folder.
echo.
pause
exit /b 1
