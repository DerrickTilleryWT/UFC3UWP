@echo off
rem ==========================================================================
rem  build-xbox.bat - UFC Undisputed 3 Recompiled for Xbox Series X|S
rem  (Developer Mode).
rem
rem  Keep everything from the download in ONE folder with no spaces in its
rem  path, for example C:\UFC3UWP. Double-click this script; the first time
rem  it asks where your extracted UFC 3 game files are (the folder with
rem  default.xex) and remembers it in game-folder.txt. Safe to run again after a failure: it
rem  skips work that is already done. Everything it does is logged to
rem  build-log.txt next to it.
rem ==========================================================================
setlocal EnableExtensions
cd /d "%~dp0"
set "ROOT=%CD%"
set "LOG=%ROOT%\build-log.txt"
set "SDK=%ROOT%\rexglue-sdk"
set "SDK_TAG=nightly-20261002-bd833a2a"
set "UFC=%ROOT%\UFC3ReX"
set "UFC_ZIP=%ROOT%\UFC3ReX-1.0.6.zip"
set "SDK_PATCH=%ROOT%\rexglue-sdk-xbox-uwp-ufc3.patch"
set "UFC_PATCH=%ROOT%\ufc3-xbox-uwp.patch"
set "SDK_UWP_INSTALL=%SDK%\out\install\uwp-amd64"
set "OUTDIR=%UFC%\out\build\uwp-amd64-release\uwp\ufc3\Release\layout"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "ERRMSG="
set "GAME="
if exist "%ROOT%\game-folder.txt" for /f "usebackq delims=" %%g in ("%ROOT%\game-folder.txt") do if not defined GAME set "GAME=%%~g"

title UFC 3 - Xbox build
echo.
echo  UFC Undisputed 3 Recompiled - Xbox build
echo  ========================================
echo  The first run takes a long time, often an hour or more.
echo  Leave this window open. Your PC may get loud and slow - that is normal.
echo  Details go to build-log.txt in this folder.
echo  Started %DATE% %TIME%

if defined GAME goto :have_game
echo.
echo  Where are your UFC Undisputed 3 game files?
echo  Drag the folder that has default.xex in it onto this window,
echo  then press Enter.
set /p GAME=Game folder: 
if not defined GAME goto :no_game
set GAME=%GAME:"=%
if not exist "%GAME%\default.xex" goto :no_game
> "%ROOT%\game-folder.txt" echo %GAME%
:have_game

call :main > "%LOG%" 2>&1
if errorlevel 1 goto :failed

echo.
echo  ==========================================================
echo   DONE. The Xbox app is built.
echo  ==========================================================
echo  Now run deploy-xbox.bat to send it to your Xbox and start it.
echo  Finished %DATE% %TIME%
echo.
pause
exit /b 0

:failed
echo.
echo  ==========================================================
echo   SOMETHING WENT WRONG
echo  ==========================================================
if defined ERRMSG echo  %ERRMSG%
if defined ERRMSG >>"%LOG%" echo ERROR: %ERRMSG%
if not defined ERRMSG >>"%LOG%" echo ERROR: the script stopped without a message.
echo.
echo  Last lines of build-log.txt:
echo  ----------------------------------------------------------
powershell -NoProfile -Command "Get-Content -LiteralPath $env:LOG -Tail 25"
echo  ----------------------------------------------------------
echo  If you can't fix it, open an issue on the GitHub page and attach
echo  build-log.txt from this folder.
echo  After a fix you can run this script again; it continues where it stopped.
echo.
pause
exit /b 1

:no_game
echo.
echo  That folder has no default.xex in it. Extract your UFC Undisputed 3
echo  disc, then run this again and give the folder that has default.xex.
echo.
pause
exit /b 1


rem ==========================================================================
:main
call :say "Step 1 of 7: Checking your files and tools"
if not "%ROOT%"=="%ROOT: =%" (set "ERRMSG=The path of this folder has spaces in it. Move the folder to a simple place like C:\ufc3x and run it again." & exit /b 1)
for %%f in ("%SDK_PATCH%" "%UFC_PATCH%" "%UFC_ZIP%") do if not exist "%%~f" (set "ERRMSG=%%~nxf is missing. Put it in the same folder as this script." & exit /b 1)
if not defined GAME (set "ERRMSG=game-folder.txt is missing or empty. Put the path of your extracted UFC 3 files in it - the folder that has default.xex." & exit /b 1)
echo Game folder: %GAME%
if not exist "%GAME%\default.xex" (set "ERRMSG=There is no default.xex in the game folder named in game-folder.txt: %GAME%" & exit /b 1)
where git >nul 2>nul
if errorlevel 1 (set "ERRMSG=Git is not installed. Install it, then run this again." & exit /b 1)
if not exist "%VSWHERE%" (set "ERRMSG=Visual Studio 2022 is not installed." & exit /b 1)

echo Visual Studio installs found:
"%VSWHERE%" -all -products * -format text -property installationPath
set "VSDIR="
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.Llvm.Clang Microsoft.VisualStudio.ComponentGroup.UWP.VC -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.ComponentGroup.UWP.VC -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (set "ERRMSG=No Visual Studio with the C++ and UWP tools was found. Install Visual Studio 2022 as the README says (C++, Clang and UWP tools)." & exit /b 1)
set "VCVARS=%VSDIR%\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "%VCVARS%" (set "ERRMSG=Visual Studio C++ tools look incomplete. Repair Visual Studio in the Visual Studio Installer." & exit /b 1)
echo Using Visual Studio: %VSDIR%

call :say "Step 2 of 7: Downloading the ReXGlue SDK - this can take a while"
if exist "%SDK%\.git" goto :sdk_update
git -c core.longpaths=true clone -c core.autocrlf=false -c core.longpaths=true https://github.com/rexglue/rexglue-sdk "%SDK%"
if errorlevel 1 (set "ERRMSG=Downloading the ReXGlue SDK failed. Check your internet, delete the rexglue-sdk folder, and run this again." & exit /b 1)
git -C "%SDK%" checkout -q %SDK_TAG%
if errorlevel 1 (set "ERRMSG=Could not select SDK version %SDK_TAG%. Delete the rexglue-sdk folder and run this again." & exit /b 1)
:sdk_update
git -c core.longpaths=true -C "%SDK%" submodule update --init --recursive
if errorlevel 1 (set "ERRMSG=Downloading the SDK's parts failed. Check your internet and run this again." & exit /b 1)

call :say "Step 3 of 7: Preparing UFC 3 Recompiled and the patches"
if exist "%UFC%\CMakeLists.txt" goto :ufc_ready
if exist "%ROOT%\ufc3-unzip" rmdir /s /q "%ROOT%\ufc3-unzip"
powershell -NoProfile -Command "Expand-Archive -LiteralPath $env:UFC_ZIP -DestinationPath (Join-Path $env:ROOT 'ufc3-unzip') -Force"
if errorlevel 1 (set "ERRMSG=Could not unpack UFC3ReX-1.0.6.zip." & exit /b 1)
for /d %%d in ("%ROOT%\ufc3-unzip\*") do if exist "%%d\CMakeLists.txt" move "%%d" "%UFC%" >nul
if not exist "%UFC%\CMakeLists.txt" (set "ERRMSG=UFC3ReX-1.0.6.zip doesn't contain the UFC 3 source." & exit /b 1)
rmdir /s /q "%ROOT%\ufc3-unzip" 2>nul
:ufc_ready
if not exist "%UFC%\.git" (
  git -C "%UFC%" init -q
  if errorlevel 1 (set "ERRMSG=git init failed in the UFC3ReX folder." & exit /b 1)
)
rem The UFC 3 project's own SDK fixes, then the Xbox changes, then any fixes.
call :apply_patch "%SDK%" "%UFC%\sdk-patch\rexglue-sdk-nightly-20261002-ufc3-fixes.patch"
if errorlevel 1 (set "ERRMSG=The UFC 3 SDK patch would not apply. Delete the rexglue-sdk folder and run this again." & exit /b 1)
call :apply_patch "%SDK%" "%SDK_PATCH%"
if errorlevel 1 (set "ERRMSG=The Xbox patch would not apply to the SDK. Delete the rexglue-sdk folder and run this again." & exit /b 1)
for %%p in ("%ROOT%\rexglue-sdk-fix-*.patch") do (
  call :apply_patch "%SDK%" "%%~fp"
  if errorlevel 1 (set "ERRMSG=A fix patch would not apply to the SDK. Open an issue on the GitHub page with build-log.txt." & exit /b 1)
)
call :apply_patch "%UFC%" "%UFC_PATCH%"
if errorlevel 1 (set "ERRMSG=The Xbox patch would not apply to UFC 3. Delete the UFC3ReX folder and run this again." & exit /b 1)
for %%p in ("%ROOT%\ufc3-fix-*.patch") do (
  call :apply_patch "%UFC%" "%%~fp"
  if errorlevel 1 (set "ERRMSG=A fix patch would not apply to UFC 3. Open an issue on the GitHub page with build-log.txt." & exit /b 1)
)
rem The code generator only needs default.xex; the full game files are sent
rem to the Xbox straight from the game folder by deploy-xbox.bat.
if not exist "%UFC%\assets" mkdir "%UFC%\assets"
copy /y "%GAME%\default.xex" "%UFC%\assets\default.xex" >nul
if errorlevel 1 (set "ERRMSG=Could not copy default.xex into the UFC3ReX folder." & exit /b 1)

call :pc_phase
if errorlevel 1 exit /b 1
call :xbox_phase
if errorlevel 1 exit /b 1
if not exist "%OUTDIR%\ufc3.exe" (set "ERRMSG=The build finished but the app files are missing." & exit /b 1)
exit /b 0


rem ==========================================================================
rem Steps 4-5 use the normal PC build tools: the code generator (rexglue.exe)
rem is a PC program.
:pc_phase
setlocal
set "ERRMSG="
call "%VCVARS%" x64
if not defined VCToolsInstallDir (set "ERRMSG=Could not start the Visual Studio build tools." & goto :pc_end)
call :use_clang
if errorlevel 1 goto :pc_end

call :say "Step 4 of 7: Building the code generator for PC"
cd /d "%SDK%"
cmake --preset win-amd64
if errorlevel 1 (set "ERRMSG=Setting up the PC SDK build failed." & goto :pc_end)
cmake --build --preset win-amd64-release --target rexglue
if errorlevel 1 (set "ERRMSG=Building the code generator failed." & goto :pc_end)
set "REXGLUE_EXE="
for /f "delims=" %%e in ('dir /s /b "%SDK%\out\win-amd64\rexglue.exe" 2^>nul') do set "REXGLUE_EXE=%%e"
if not defined REXGLUE_EXE (set "ERRMSG=The code generator was built but rexglue.exe wasn't found." & goto :pc_end)
echo Code generator: %REXGLUE_EXE%
> "%ROOT%\rexglue-exe.txt" echo %REXGLUE_EXE%

call :say "Step 5 of 7: Turning the Xbox 360 game code into C++"
cd /d "%UFC%"
"%REXGLUE_EXE%" codegen ufc3_manifest.toml
if errorlevel 1 (set "ERRMSG=Generating the game code failed. Make sure the game folder is UFC Undisputed 3." & goto :pc_end)
:pc_end
endlocal & set "ERRMSG=%ERRMSG%"
if defined ERRMSG exit /b 1
exit /b 0


rem ==========================================================================
rem Steps 6-7 use the UWP (Xbox app) build tools.
:xbox_phase
setlocal
set "ERRMSG="
call "%VCVARS%" x64 uwp
if not defined VCToolsInstallDir (set "ERRMSG=Could not start the Visual Studio build tools for Xbox apps." & goto :xbox_end)
if not exist "%VCToolsInstallDir%lib\x64\store" (set "ERRMSG=The C++ Universal Windows Platform tools are missing. Add them in the Visual Studio Installer." & goto :xbox_end)
call :use_clang
if errorlevel 1 goto :xbox_end
set /p REXGLUE_EXE=<"%ROOT%\rexglue-exe.txt"

call :say "Step 6 of 7: Building the SDK for Xbox - the longest step"
cd /d "%SDK%"
set "FRESH="
if not exist "%SDK%\out\build\uwp-amd64\build.ninja" set "FRESH=--fresh"
cmake --preset uwp-amd64 %FRESH%
if errorlevel 1 (set "ERRMSG=Setting up the Xbox SDK build failed." & goto :xbox_end)
cmake --build --preset uwp-amd64-release
if errorlevel 1 (set "ERRMSG=Building the Xbox SDK failed." & goto :xbox_end)
cmake --install out/build/uwp-amd64 --config Release --prefix "%SDK_UWP_INSTALL%"
if errorlevel 1 (set "ERRMSG=Installing the Xbox SDK failed." & goto :xbox_end)

call :say "Step 7 of 7: Building UFC 3 for Xbox"
set "UFC3_SDK_UWP=%SDK_UWP_INSTALL%"
set "SDK_CMAKE=%SDK_UWP_INSTALL:\=/%"
set "TOOL_CMAKE=%REXGLUE_EXE:\=/%"
cd /d "%UFC%"
set "FRESH="
if not exist "%UFC%\out\build\uwp-amd64-release\build.ninja" set "FRESH=--fresh"
cmake --preset uwp-amd64-release %FRESH% "-DCMAKE_PREFIX_PATH=%SDK_CMAKE%" "-Drexglue_DIR=%SDK_CMAKE%/lib/cmake/rexglue" "-DREXGLUE_CODEGEN_TOOL=%TOOL_CMAKE%"
if errorlevel 1 (set "ERRMSG=Setting up the Xbox game build failed." & goto :xbox_end)
cmake --build --preset uwp-amd64-release --target ufc3
if errorlevel 1 (set "ERRMSG=Building the Xbox game failed." & goto :xbox_end)
:xbox_end
endlocal & set "ERRMSG=%ERRMSG%"
if defined ERRMSG exit /b 1
exit /b 0


rem ==========================================================================
rem Puts Clang 18 or newer first on PATH: a separately installed LLVM if
rem there is one, otherwise the one that comes with Visual Studio.
:use_clang
set "LLVMBIN="
if exist "%VSDIR%\VC\Tools\Llvm\x64\bin\clang.exe" set "LLVMBIN=%VSDIR%\VC\Tools\Llvm\x64\bin"
if exist "%ProgramFiles%\LLVM\bin\clang.exe" set "LLVMBIN=%ProgramFiles%\LLVM\bin"
if defined LLVMBIN set "PATH=%LLVMBIN%;%PATH%"
echo Clang folder chosen: %LLVMBIN%
clang --version
set "CLANGVER="
for /f "tokens=3" %%v in ('clang --version 2^>nul ^| findstr /b /c:"clang version"') do set "CLANGVER=%%v"
if not defined CLANGVER (set "ERRMSG=The Clang compiler was not found. Add C++ Clang Compiler for Windows in the Visual Studio Installer." & exit /b 1)
set "CLANGMAJOR="
for /f "delims=." %%m in ("%CLANGVER%") do set "CLANGMAJOR=%%m"
if %CLANGMAJOR% LSS 18 (set "ERRMSG=Clang %CLANGVER% is too old - version 18 or newer is needed. Update Visual Studio 2022 in the Visual Studio Installer." & exit /b 1)
echo Using clang %CLANGVER%
where cmake
where ninja
where cmake >nul 2>nul
if errorlevel 1 (set "ERRMSG=CMake was not found. Add C++ CMake tools for Windows in the Visual Studio Installer." & exit /b 1)
where ninja >nul 2>nul
if errorlevel 1 (set "ERRMSG=Ninja was not found. Add C++ CMake tools for Windows in the Visual Studio Installer." & exit /b 1)
exit /b 0


rem ==========================================================================
rem Applies a patch unless it is already applied. Arguments: repo folder,
rem patch file. A marker file in the repo's .git folder records each applied
rem patch, because a later fix patch can change the same lines, after which
rem git can no longer tell that the earlier patch is in place.
:apply_patch
set "MARKDIR=%~1\.git\rb2x-applied"
set "MARK=%MARKDIR%\%~nx2"
if exist "%MARK%" goto :apply_patch_done
git -C "%~1" apply -R --check "%~2" >nul 2>nul
if not errorlevel 1 goto :apply_patch_mark
git -C "%~1" apply --whitespace=nowarn "%~2"
if errorlevel 1 exit /b 1
echo Applied patch: %~nx2
:apply_patch_mark
if not exist "%MARKDIR%" mkdir "%MARKDIR%"
echo done> "%MARK%"
:apply_patch_done
echo Patch in place: %~nx2
exit /b 0


rem ==========================================================================
rem Shows a progress line in the window and writes it to the log.
:say
echo.
echo ==== %~1
>con echo.
>con echo  %~1
exit /b 0
