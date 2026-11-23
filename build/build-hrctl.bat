@echo off
setlocal
call "%~dp0env.bat" || exit /b 1
cd /d "%~dp0..\tools\hrctl"
if not exist bin mkdir bin
if not exist dcu mkdir dcu
dcc32.exe -B -Q -$O+ -Ebin -NUdcu -NSSystem;Winapi hrctl.dpr
echo DCC32_EXIT=%ERRORLEVEL%
