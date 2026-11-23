@echo off
setlocal
rem Remove o plugin Hot Reload do Delphi 12 (feche o Delphi antes).
set "AQUI=%~dp0"
set "AQUI=%AQUI:~0,-1%"
set "BPL=%AQUI%\tools\ide\bin\HotReloadIDE.bpl"
set "CHAVE_PACOTES=HKCU\Software\Embarcadero\BDS\23.0\Known Packages"
set "CHAVE_HR=HKCU\Software\HotReloadIDE"

tasklist /fi "imagename eq bds.exe" 2>nul | findstr /i "bds.exe" >nul
if not errorlevel 1 (
  echo Feche o Delphi antes de desinstalar.
  goto fim
)
reg delete "%CHAVE_PACOTES%" /v "%BPL%" /f >nul 2>&1
reg delete "%CHAVE_HR%" /f >nul 2>&1
echo Removido. Os projetos ativados continuam compilando normalmente fora da configuracao HotReload.
:fim
if not defined HOTRELOAD_SEM_PAUSA pause
