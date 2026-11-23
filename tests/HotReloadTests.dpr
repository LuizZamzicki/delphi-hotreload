program HotReloadTests;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  HotReload.DfmModel in '..\src\HotReload.DfmModel.pas',
  HotReload.DfmApply in '..\src\HotReload.DfmApply.pas',
  HotReload.Patch in '..\src\HotReload.Patch.pas',
  HotReload.Control in '..\src\HotReload.Control.pas',
  HotReload in '..\src\HotReload.pas',
  uTestForm in 'uTestForm.pas' {TestForm};

var
  Failures, Checks: Integer;
  LogLines: TStringList;
  TestsDir, DataDir: string;

procedure Check(Cond: Boolean; const What: string);
begin
  Inc(Checks);
  if Cond then
    Writeln('  ok    ', What)
  else
  begin
    Inc(Failures);
    Writeln('  FALHA ', What);
  end;
end;

procedure CollectLog(const Msg: string);
begin
  LogLines.Add(Msg);
  Writeln('        | ', Msg);
end;

function LogHas(const S: string): Boolean;
begin
  Result := Pos(S, LogLines.Text) > 0;
end;

function CodeOf(E: TNotifyEvent): Pointer;
begin
  Result := TMethod(E).Code;
end;

function BaseText: string;
begin
  Result := DfmFileToCanonicalText(TPath.Combine(TestsDir, 'uTestForm.dfm'));
end;

function DataText(const Name: string): string;
begin
  Result := DfmFileToCanonicalText(TPath.Combine(DataDir, Name));
end;

procedure TestParser;
const
  Sample =
    'object F: TForm'#13#10 +
    '  Caption = ''x'''#13#10 +
    '  object LV: TListView'#13#10 +
    '    Columns = <'#13#10 +
    '      item'#13#10 +
    '        Caption = ''a'''#13#10 +
    '      end'#13#10 +
    '      item'#13#10 +
    '        Caption = ''b'''#13#10 +
    '      end>'#13#10 +
    '    TabOrder = 0'#13#10 +
    '  end'#13#10 +
    '  inline Fr1: TFrame1'#13#10 +
    '    inherited Btn: TButton'#13#10 +
    '      Caption = ''y'''#13#10 +
    '    end'#13#10 +
    '  end'#13#10 +
    'end'#13#10;
var
  Root: TDfmNode;
begin
  Writeln('Parser');
  Root := ParseDfm(Sample);
  try
    Check(Root.TypeName = 'TForm', 'raiz TForm');
    Check(Root.Props.Count = 1, 'raiz com 1 propriedade');
    Check(Root.Children.Count = 2, 'raiz com 2 filhos');
    Check(Root.Children[0].Props.Count = 2, 'coleção conta como uma propriedade só');
    Check(Root.Children[0].Props[0].Name = 'Columns', 'nome da coleção');
    Check(Root.Children[1].Kind = dkInline, 'frame inline');
    Check(Root.Children[1].Children[0].Key = 'Fr1.Btn', 'key de componente dentro de frame');
    Check(DfmHeaderClassName(Sample) = 'TForm', 'classe do cabeçalho');
  finally
    Root.Free;
  end;
end;

procedure TestDelta;
var
  Old, New: TDfmNode;
  D: TDfmDelta;
begin
  Writeln('Delta');
  Old := ParseDfm(BaseText);
  New := ParseDfm(DataText('uTestForm.v2.dfm'));
  D := BuildDfmDelta(Old, New);
  try
    Writeln(D.Text);
    Check(Pos('inherited Button1: TButton', D.Text) > 0, 'Button1 vai como inherited');
    Check(Pos('Caption = ''Depois''', D.Text) > 0, 'Caption novo no delta');
    Check(Pos('object Label2: TLabel', D.Text) > 0, 'Label2 novo vai como object');
    Check(Pos('Memo1', D.Text) = 0, 'Memo1 removido não aparece no texto');
    Check(Pos('Width = 185', D.Text) = 0, 'propriedade igual não vai no delta');
    Check(D.Count(okFree) = 1, 'uma remoção (Memo1)');
    Check(D.Count(okReparent) = 1, 'uma mudança de pai (Button1)');
    Check(D.Count(okResetProp) = 1, 'Font.Style do Label1 volta ao padrão');
  finally
    D.Free;
    New.Free;
    Old.Free;
  end;
end;

procedure TestApply;
var
  F: TTestForm;
  Base, V2, V3: string;
  C: TComponent;
begin
  Writeln('Aplicar na tela viva');
  F := TTestForm.Create(nil);
  try
    Check(DfmResourceText(TTestForm, Base), 'DFM de origem lido do exe');
    Check(Base = BaseText, 'DFM do exe igual ao do disco depois de normalizar');
    V2 := DataText('uTestForm.v2.dfm');
    V3 := DataText('uTestForm.v3.dfm');

    LogLines.Clear;
    Check(ApplyDfmText(F, Base, V2, CollectLog), 'base -> v2 aplicado');
    Check(F.Name = 'TestForm', 'form não foi renomeado');
    Check(F.Caption = 'Teste v2', 'Caption do form');
    Check(F.Button1.Caption = 'Depois', 'Caption do Button1');
    Check(F.Button1.Parent = F.Panel2, 'Button1 mudou para o Panel2');
    Check((F.Button1.Left = 24) and (F.Button1.Top = 24), 'Button1 na posição nova');
    Check(F.Panel1.Color = clRed, 'Panel1 vermelho');
    Check(not (fsBold in F.Label1.Font.Style), 'Label1 perdeu o negrito (propriedade removida)');
    Check(F.Memo1 = nil, 'Memo1 removido e campo zerado');
    C := F.FindComponent('Label2');
    Check((C is TLabel) and (TLabel(C).Caption = 'Nova') and (TLabel(C).Parent = F.Panel2), 'Label2 criado no Panel2');
    C := F.FindComponent('CheckBox1');
    // TCheckBox não é campo do TTestForm: vem da varredura de VMTs. Ele só está inteiro no
    // exe por causa do "= TCheckBox" no fim do programa; um "is TCheckBox" sozinho não basta.
    Check((C is TCheckBox) and (TCheckBox(C).Parent = F.Panel2), 'CheckBox1 criado (classe que não é campo do form)');
    Check(CodeOf(F.Button1.OnClick) = F.MethodAddress('Button2Click'), 'OnClick trocado para Button2Click');

    LogLines.Clear;
    Check(ApplyDfmText(F, V2, V3, CollectLog), 'v2 -> v3 aplicado');
    Check(F.FindComponent('Label2') = nil, 'Label2 removido');
    Check(LogHas('Inexistente'), 'aviso de método inexistente');
    Check(CodeOf(F.Button1.OnClick) = F.MethodAddress('Button2Click'), 'OnClick mantido quando o método não existe');

    LogLines.Clear;
    Check(ApplyDfmText(F, V3, Base, CollectLog), 'v3 -> base aplicado');
    Check(F.Caption = 'Teste', 'Caption original');
    Check(F.Button1.Parent = F.Panel1, 'Button1 voltou para o Panel1');
    Check(fsBold in F.Label1.Font.Style, 'Label1 negrito de novo');
    Check((F.Memo1 <> nil) and (F.Memo1.Lines.Count = 1) and (F.Memo1.Lines[0] = 'linha1'),
      'Memo1 recriado e campo religado');
    Check(F.Panel1.Color = clBtnFace, 'Panel1.Color voltou ao padrão');
    Check(F.FindComponent('CheckBox1') = nil, 'CheckBox1 removido');
    Check(CodeOf(F.Button1.OnClick) = F.MethodAddress('Button1Click'), 'OnClick de volta no Button1Click');

    LogLines.Clear;
    Check(not ApplyDfmText(F, Base, Base, CollectLog), 'mesmo texto: nada a aplicar');
  finally
    F.Free;
  end;
end;

procedure Pump(Ms: Integer; const Done: TFunc<Boolean>);
var
  T0: UInt64;
begin
  T0 := GetTickCount64;
  while (GetTickCount64 - T0 < UInt64(Ms)) and not Done() do
  begin
    CheckSynchronize(10);
    Application.ProcessMessages;
  end;
end;

procedure TestWatcher;
var
  Dir, Target: string;
  F2, F3: TTestForm;
begin
  Writeln('Vigia de arquivos (ponta a ponta)');
  Dir := TPath.Combine(TPath.GetTempPath, 'hotreload-test-' + IntToStr(GetTickCount64));
  TDirectory.CreateDirectory(Dir);
  Target := TPath.Combine(Dir, 'uTestForm.dfm');
  TFile.Copy(TPath.Combine(TestsDir, 'uTestForm.dfm'), Target);
  F2 := TTestForm.Create(nil);
  F3 := nil;
  try
    LogLines.Clear;
    THotReload.OnLog := CollectLog;
    THotReload.Start([Dir]);
    Pump(300, function: Boolean begin Result := False end);
    TFile.Copy(TPath.Combine(DataDir, 'uTestForm.v2.dfm'), Target, True);
    Pump(5000, function: Boolean begin Result := F2.Button1.Caption = 'Depois' end);
    Check(F2.Button1.Caption = 'Depois', 'tela aberta recebeu a mudança salva no disco');
    F3 := TTestForm.Create(nil);
    Pump(3000, function: Boolean begin Result := F3.Button1.Caption = 'Depois' end);
    Check(F3.Button1.Caption = 'Depois', 'tela aberta depois da mudança também recebe');
    Check(F3.Memo1 = nil, 'e com o Memo1 removido');
  finally
    THotReload.Stop;
    THotReload.OnLog := nil;
    F3.Free;
    F2.Free;
    TDirectory.Delete(Dir, True);
  end;
end;

begin
  SetConsoleOutputCP(CP_UTF8);
  SetTextCodePage(Output, CP_UTF8);
  LogLines := TStringList.Create;
  TestsDir := ExtractFileDir(ExtractFileDir(ParamStr(0))); // exe em tests\bin
  DataDir := TPath.Combine(TestsDir, 'data');
  Application.Initialize;
  try
    TestParser;
    TestDelta;
    TestApply;
    TestWatcher;
    Writeln('Classes');
    Check(FindComponentClassByName('TCheckBox') = TCheckBox, 'classe achada na varredura de VMTs');
    Check(FindComponentClassByName('TNaoExiste') = nil, 'classe inexistente devolve nil');
  except
    on E: Exception do
    begin
      Inc(Failures);
      Writeln('EXCEÇÃO ', E.ClassName, ': ', E.Message);
    end;
  end;
  Writeln;
  Writeln(Format('%d verificações, %d falha(s)', [Checks, Failures]));
  LogLines.Free;
  ExitCode := Failures;
end.
