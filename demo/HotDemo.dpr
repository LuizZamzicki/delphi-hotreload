program HotDemo;

uses
  Vcl.Forms,
  System.SysUtils,
  HotReload.DfmModel in '..\src\HotReload.DfmModel.pas',
  HotReload.DfmApply in '..\src\HotReload.DfmApply.pas',
  HotReload.Patch in '..\src\HotReload.Patch.pas',
  HotReload.Control in '..\src\HotReload.Control.pas',
  HotReload in '..\src\HotReload.pas',
  uMain in 'uMain.pas' {FormMain},
  uSecond in 'uSecond.pas' {FormSecond};

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFormMain, FormMain);
  {$IFDEF DEBUG}
  THotReload.Start([ExtractFileDir(ExtractFileDir(ParamStr(0)))]);
  {$ENDIF}
  Application.Run;
end.
