@echo off
setlocal
rem Compila o plugin da IDE: tools\ide\bin\HotReloadIDE.bpl
rem Instalar: Component > Install Packages > Add... e escolher esse .bpl
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat" >nul
cd /d "%~dp0..\tools\ide"
if not exist bin mkdir bin
if not exist dcu mkdir dcu
dcc32.exe -B -Q -LEbin -LNbin -NUdcu -NSSystem;Winapi;Vcl;System.Win HotReloadIDE.dpk
set RC=%ERRORLEVEL%
echo DCC32_EXIT=%RC%
exit /b %RC%
