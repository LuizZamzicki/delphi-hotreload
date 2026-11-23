@echo off
rem Acha o Delphi 12 (BDS 23.0) pelo registro (ou pela variavel BDS) e carrega o rsvars.bat.
if defined BDS if exist "%BDS%\bin\rsvars.bat" goto achou
for %%K in (HKCU HKLM) do (
  for /f "tokens=2,*" %%A in ('reg query "%%K\Software\Embarcadero\BDS\23.0" /v RootDir 2^>nul ^| findstr /c:"RootDir"') do set "BDS=%%B"
  if defined BDS goto achou
)
echo Nao achei o Delphi 12 (BDS 23.0). Defina a variavel BDS com a pasta de instalacao.
exit /b 1
:achou
if "%BDS:~-1%"=="\" set "BDS=%BDS:~0,-1%"
call "%BDS%\bin\rsvars.bat" >nul
exit /b 0
