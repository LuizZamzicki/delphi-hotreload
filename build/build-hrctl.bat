@echo off
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat" >nul
cd /d "%~dp0..\tools\hrctl"
if not exist bin mkdir bin
if not exist dcu mkdir dcu
dcc32.exe -B -Q -$O+ -Ebin -NUdcu -NSSystem;Winapi hrctl.dpr
echo DCC32_EXIT=%ERRORLEVEL%
