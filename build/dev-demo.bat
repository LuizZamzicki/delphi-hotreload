@echo off
setlocal
rem Abre o demo e deixa o hrctl watch aplicando as mudancas sozinho (modo para humanos):
rem   .dfm salvo -> o proprio exe aplica na tela aberta
rem   .pas salvo -> hrctl patch (troca o codigo sem fechar); se mexeu em estrutura, R reinicia
cd /d "%~dp0.."
set HRCTL=%CD%\tools\hrctl\bin\hrctl.exe
"%HRCTL%" list >/dev/null 2>&1
if %ERRORLEVEL%==0 goto vigiar
call build\make-demo.bat
if errorlevel 1 (
  echo.
  echo O build falhou; corrija e rode de novo.
  pause
  exit /b 1
)
start "" demo\bin\HotDemo.exe
:vigiar
"%HRCTL%" watch --dir demo --patch-build "build\patch-demo.bat" --new "demo\bin\patch\HotDemo.exe" --build "build\make-demo.bat"
