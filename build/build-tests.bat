@echo off
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat" >nul
cd /d "%~dp0..\tests"
if not exist bin mkdir bin
if not exist dcu mkdir dcu
dcc32.exe -B -Q -DDEBUG -$D+ -$L+ -$O- -$C+ -GD -Ebin -NUdcu -NSSystem;Winapi;Vcl;System.Win;Data -U..\src HotReloadTests.dpr
echo DCC32_EXIT=%ERRORLEVEL%
if errorlevel 1 exit /b 1
bin\HotReloadTests.exe
echo TESTS_EXIT=%ERRORLEVEL%
