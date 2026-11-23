@echo off
setlocal
rem Instala o plugin Hot Reload no Delphi 12 (feche o Delphi antes).
rem Registra o pacote na IDE e a pasta onde ficam src\ e tools\hrctl\bin\hrctl.exe.
set "AQUI=%~dp0"
set "AQUI=%AQUI:~0,-1%"
set "BPL=%AQUI%\tools\ide\bin\HotReloadIDE.bpl"
set "CHAVE_PACOTES=HKCU\Software\Embarcadero\BDS\23.0\Known Packages"
set "CHAVE_HR=HKCU\Software\HotReloadIDE"

if not exist "%BPL%" (
  echo Nao achei %BPL%.
  echo Use o zip da Release ou rode build\build-ide.bat antes.
  goto fim
)
if not exist "%AQUI%\tools\hrctl\bin\hrctl.exe" (
  echo Nao achei tools\hrctl\bin\hrctl.exe. Use o zip da Release ou rode build\build-hrctl.bat antes.
  goto fim
)
tasklist /fi "imagename eq bds.exe" 2>nul | findstr /i "bds.exe" >nul
if not errorlevel 1 (
  echo Feche o Delphi antes de instalar.
  goto fim
)
reg add "%CHAVE_HR%" /v Home /d "%AQUI%" /f >nul || goto erro
reg add "%CHAVE_PACOTES%" /v "%BPL%" /d "Hot reload para Delphi (menu Hot Reload)" /f >nul || goto erro
echo Instalado. Abra o Delphi 12: aparece o menu Hot Reload.
goto fim
:erro
echo Nao consegui gravar no registro.
:fim
if not defined HOTRELOAD_SEM_PAUSA pause
