@echo off
setlocal
rem Build do patch de codigo (nivel 3): exe novo, .map e .obj em demo\bin\patch, sem tocar no exe vivo.
rem 1) -J recompila so as units alteradas e grava .dcu + .obj (com -J o dcc32 nao linka o exe)
rem 2) build normal na mesma pasta: os .dcu ja estao em dia, so linka exe + .map
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat" >nul
cd /d "%~dp0..\demo"
if not exist bin\patch mkdir bin\patch
if not exist dcu mkdir dcu
dcc32.exe -Q -J -DDEBUG -$D+ -$L+ -$O- -NObin\patch -NUdcu -NSSystem;Winapi;Vcl;System.Win;Data -U..\src HotDemo.dpr
set RC=%ERRORLEVEL%
if not %RC%==0 goto fim
dcc32.exe -Q -DDEBUG -$D+ -$L+ -$O- -GD -Ebin\patch -NUdcu -NSSystem;Winapi;Vcl;System.Win;Data -U..\src HotDemo.dpr
set RC=%ERRORLEVEL%
:fim
echo DCC32_EXIT=%RC%
exit /b %RC%
