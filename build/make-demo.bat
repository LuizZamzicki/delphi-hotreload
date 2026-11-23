@echo off
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat" >nul
cd /d "%~dp0..\demo"
if not exist bin mkdir bin
if not exist dcu mkdir dcu
copy /y hotreload.ini bin\ >nul
dcc32.exe -Q -DDEBUG -$D+ -$L+ -$O- -GD -Ebin -NUdcu -NSSystem;Winapi;Vcl;System.Win;Data -U..\src HotDemo.dpr
set RC=%ERRORLEVEL%
echo DCC32_EXIT=%RC%
exit /b %RC%
