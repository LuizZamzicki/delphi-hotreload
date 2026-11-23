@echo off
setlocal
rem Compila o plugin da IDE: tools\ide\bin\HotReloadIDE.bpl
rem Instalar: Component > Install Packages > Add... e escolher esse .bpl
call "%~dp0env.bat" || exit /b 1
cd /d "%~dp0..\tools\ide"
if not exist bin mkdir bin
if not exist dcu mkdir dcu
dcc32.exe -B -Q -LEbin -LNbin -NUdcu -NSSystem;Winapi;Vcl;System.Win HotReloadIDE.dpk
set RC=%ERRORLEVEL%
rem O plugin acha src\ e o hrctl.exe por aqui, de onde quer que a IDE carregue o .bpl
for %%I in ("%~dp0..") do reg add HKCU\Software\HotReloadIDE /v Home /d "%%~fI" /f >nul
echo DCC32_EXIT=%RC%
exit /b %RC%
