unit HotReload.IDE;

(*
  Plugin da IDE (Delphi 12) para o hot reload: faz na própria IDE o papel do "hrctl watch".

  Menu "Hot Reload":
    - Ativar neste projeto: cria a build configuration HotReload (filha da Release, com o define
      HOTRELOAD e .map detalhado) e acrescenta ao .dpr, dentro de {$IFDEF HOTRELOAD}, as units de
      ..\..\..\src (relativas a este pacote) e o THotReload.Start([]).
    - Patch agora / Reiniciar.
    - Patch automático ao salvar (ligado por padrão).

  Ao salvar um .pas do projeto ativo, com a configuração HotReload selecionada e o conteúdo
  mudado, roda em segundo plano "hrctl patch" (o .dfm o próprio exe aplica). Os comandos de
  build vêm de "hrctl setup", que lê as opções da IDE pelo msbuild: nada fica preso à máquina.
  O resultado vai para a janela Messages, grupo "Hot Reload"; erro de compilação leva à linha.

  O hrctl.exe é procurado em ..\..\hrctl\bin\hrctl.exe, a partir da pasta deste .bpl.
*)

interface

procedure Register;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.IOUtils, System.Hash,
  System.Win.Registry, System.Generics.Collections, System.RegularExpressions, System.StrUtils,
  Vcl.Menus, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, ToolsAPI;

const
  ConfigName = 'HotReload';
  GroupName = 'Hot Reload';
  RegKey = 'Software\HotReloadIDE';

type
  TSetupInfo = record
    Valid: Boolean;
    Stamp: TDateTime; // data do .dproj quando o setup rodou
    Exe, Make, Patch, NewExe: string;
  end;

  TExpert = class;

  TModNotifier = class(TNotifierObject, IOTANotifier, IOTAModuleNotifier)
  private
    FModule: IOTAModule;
    FIndex: Integer;
  public
    constructor Create(const AModule: IOTAModule);
    procedure Detach;
    procedure AfterSave;
    procedure Destroyed;
    function CheckOverwrite: Boolean;
    procedure ModuleRenamed(const NewName: string);
  end;

  TIDENotifier = class(TNotifierObject, IOTAIDENotifier)
  public
    procedure FileNotification(NotifyCode: TOTAFileNotification; const FileName: string; var Cancel: Boolean);
    procedure BeforeCompile(const Project: IOTAProject; var Cancel: Boolean); overload;
    procedure AfterCompile(Succeeded: Boolean); overload;
  end;

  TExpert = class(TComponent)
  private
    FMenu, FAuto: TMenuItem;
    FIDEIndex: Integer;
    FMods: TDictionary<string, TModNotifier>;
    FHashes: TDictionary<string, string>;
    FSetups: TDictionary<string, TSetupInfo>;
    FTimer, FScan: TTimer;
    FPending: TStringList;
    FBusy: Boolean;
    function Group: IOTAMessageGroup;
    procedure Title(const S: string; Show: Boolean = False);
    procedure ToolMsg(const FileName, S: string; Line: Integer);
    function HrctlPath: string;
    function SrcDir: string;
    function ActiveConfig(const P: IOTAProject): string;
    function ProjectReady(out P: IOTAProject): Boolean;
    procedure AddMenu;
    procedure DoActivate(Sender: TObject);
    procedure DoPatchNow(Sender: TObject);
    procedure DoRestart(Sender: TObject);
    procedure DoToggleAuto(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure ScanTick(Sender: TObject);
    procedure Run(const Caption, Command: string; const Done: TProc<Integer, TStrings>);
    procedure WithSetup(const P: IOTAProject; const Next: TProc<TSetupInfo>);
    procedure StartPatch(const Reason: string);
    procedure PatchDone(Code: Integer; Output: TStrings; T0: UInt64);
    procedure ReportErrors(Output: TStrings; const ProjDir: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Attach(const M: IOTAModule);
    procedure Forget(N: TModNotifier);
    procedure FileSaved(const FileName: string);
  end;

var
  GExpert: TExpert;

procedure Finished(Code: Integer; const Output: string; const Done: TProc<Integer, TStrings>); forward;

{ Processo em segundo plano }

function Capture(const Command, Dir: string; out Output: string): Integer;
var
  SA: TSecurityAttributes;
  Rd, Wr: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Line: string;
  Buf: array[0..8191] of Byte;
  N: DWORD;
  Data: TBytesStream;
  Code: DWORD;
begin
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;
  if not CreatePipe(Rd, Wr, @SA, 0) then
    RaiseLastOSError;
  SetHandleInformation(Rd, HANDLE_FLAG_INHERIT, 0);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdOutput := Wr;
  SI.hStdError := Wr;
  Line := 'cmd.exe /s /c "' + Command + '"';
  UniqueString(Line);
  if not CreateProcess(nil, PChar(Line), nil, nil, True, CREATE_NO_WINDOW, nil, PChar(Dir), SI, PI) then
  begin
    CloseHandle(Rd);
    CloseHandle(Wr);
    RaiseLastOSError;
  end;
  CloseHandle(Wr);
  Data := TBytesStream.Create;
  try
    while ReadFile(Rd, Buf, SizeOf(Buf), N, nil) and (N > 0) do
      Data.WriteBuffer(Buf, N);
    WaitForSingleObject(PI.hProcess, INFINITE);
    GetExitCodeProcess(PI.hProcess, Code);
    Result := Integer(Code);
    Output := TEncoding.UTF8.GetString(Data.Bytes, 0, Data.Size); // o hrctl escreve UTF-8
  finally
    Data.Free;
    CloseHandle(Rd);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end;
end;

{ TModNotifier }

constructor TModNotifier.Create(const AModule: IOTAModule);
begin
  inherited Create;
  FModule := AModule;
  FIndex := -1;
end;

procedure TModNotifier.Detach;
var
  I: Integer;
begin
  I := FIndex;
  FIndex := -1;
  if (I >= 0) and (FModule <> nil) then
    FModule.RemoveNotifier(I); // pode liberar este objeto: não mexer em nada depois
end;

procedure TModNotifier.AfterSave;
begin
  if (GExpert <> nil) and (FModule <> nil) then
    GExpert.FileSaved(FModule.FileName);
end;

procedure TModNotifier.Destroyed;
var
  M: IOTAModule;
  I: Integer;
begin
  // RemoveNotifier pode liberar este objeto: copia e limpa os campos antes.
  M := FModule;
  I := FIndex;
  FModule := nil;
  FIndex := -1;
  if GExpert <> nil then
    GExpert.Forget(Self);
  if (M <> nil) and (I >= 0) then
    M.RemoveNotifier(I);
end;

function TModNotifier.CheckOverwrite: Boolean;
begin
  Result := True;
end;

procedure TModNotifier.ModuleRenamed(const NewName: string);
begin
end;

{ TIDENotifier }

procedure TIDENotifier.FileNotification(NotifyCode: TOTAFileNotification; const FileName: string;
  var Cancel: Boolean);
var
  M: IOTAModule;
begin
  if (NotifyCode = ofnFileOpened) and (GExpert <> nil) then
  begin
    M := (BorlandIDEServices as IOTAModuleServices).FindModule(FileName);
    if M <> nil then
      GExpert.Attach(M);
  end;
end;

procedure TIDENotifier.BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
begin
end;

procedure TIDENotifier.AfterCompile(Succeeded: Boolean);
begin
end;

{ TExpert }

constructor TExpert.Create(AOwner: TComponent);
var
  MS: IOTAModuleServices;
  I: Integer;
begin
  inherited;
  FMods := TDictionary<string, TModNotifier>.Create;
  FHashes := TDictionary<string, string>.Create;
  FSetups := TDictionary<string, TSetupInfo>.Create;
  FPending := TStringList.Create;
  FPending.Sorted := True;
  FPending.Duplicates := dupIgnore;
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 700; // a IDE salva .pas e .dfm em sequência
  FTimer.OnTimer := TimerTick;
  // No aviso de arquivo aberto o módulo às vezes ainda não existe: varre de tempos em tempos.
  FScan := TTimer.Create(Self);
  FScan.Interval := 2000;
  FScan.OnTimer := ScanTick;
  AddMenu;
  FIDEIndex := (BorlandIDEServices as IOTAServices).AddNotifier(TIDENotifier.Create);
  MS := BorlandIDEServices as IOTAModuleServices;
  for I := 0 to MS.ModuleCount - 1 do
    Attach(MS.Modules[I]);
end;

destructor TExpert.Destroy;
var
  N: TModNotifier;
  L: TArray<TModNotifier>;
begin
  if FIDEIndex >= 0 then
    (BorlandIDEServices as IOTAServices).RemoveNotifier(FIDEIndex);
  L := FMods.Values.ToArray;
  FMods.Clear;
  for N in L do
    N.Detach;
  FMenu.Free;
  FPending.Free;
  FSetups.Free;
  FHashes.Free;
  FMods.Free;
  inherited;
end;

procedure TExpert.Attach(const M: IOTAModule);
var
  Key: string;
  N: TModNotifier;
begin
  Key := LowerCase(M.FileName);
  if FMods.ContainsKey(Key) then
    Exit;
  N := TModNotifier.Create(M);
  N.FIndex := M.AddNotifier(N);
  FMods.Add(Key, N);
  if SameText(ExtractFileExt(M.FileName), '.pas') and FileExists(M.FileName) then
    FHashes.AddOrSetValue(Key, THashMD5.GetHashStringFromFile(M.FileName));
end;

procedure TExpert.ScanTick(Sender: TObject);
var
  MS: IOTAModuleServices;
  I: Integer;
begin
  MS := BorlandIDEServices as IOTAModuleServices;
  for I := 0 to MS.ModuleCount - 1 do
    Attach(MS.Modules[I]);
end;

procedure TExpert.Forget(N: TModNotifier);
var
  Pair: TPair<string, TModNotifier>;
begin
  for Pair in FMods do
    if Pair.Value = N then
    begin
      FMods.Remove(Pair.Key);
      Exit;
    end;
end;

function TExpert.Group: IOTAMessageGroup;
var
  MS: IOTAMessageServices;
begin
  MS := BorlandIDEServices as IOTAMessageServices;
  Result := MS.GetGroup(GroupName);
  if Result = nil then
    Result := MS.AddMessageGroup(GroupName);
end;

procedure TExpert.Title(const S: string; Show: Boolean);
var
  MS: IOTAMessageServices;
  G: IOTAMessageGroup;
begin
  MS := BorlandIDEServices as IOTAMessageServices;
  G := Group;
  MS.AddTitleMessage(FormatDateTime('hh:nn:ss  ', Now) + S, G);
  if Show then
    MS.ShowMessageView(G);
end;

procedure TExpert.ToolMsg(const FileName, S: string; Line: Integer);
var
  Ref: Pointer;
begin
  (BorlandIDEServices as IOTAMessageServices).AddToolMessage(FileName, S, GroupName, Line, 1, nil, Ref, Group);
end;

function TExpert.HrctlPath: string;
begin
  // <repo>\tools\ide\bin\HotReloadIDE.bpl  ->  <repo>\tools\hrctl\bin\hrctl.exe
  Result := ExpandFileName(ExtractFilePath(GetModuleName(HInstance)) + '..\..\hrctl\bin\hrctl.exe');
end;

function TExpert.SrcDir: string;
begin
  Result := ExpandFileName(ExtractFilePath(GetModuleName(HInstance)) + '..\..\..\src\');
end;

function TExpert.ActiveConfig(const P: IOTAProject): string;
var
  C: IOTAProjectOptionsConfigurations;
begin
  Result := '';
  if Supports(P.ProjectOptions, IOTAProjectOptionsConfigurations, C) and (C.ActiveConfiguration <> nil) then
    Result := C.ActiveConfiguration.Name;
end;

function TExpert.ProjectReady(out P: IOTAProject): Boolean;
begin
  P := GetActiveProject;
  Result := False;
  if P = nil then
  begin
    Title('nenhum projeto ativo', True);
    Exit;
  end;
  if not FileExists(HrctlPath) then
  begin
    Title('hrctl.exe não encontrado em ' + HrctlPath + ' (rode build\build-hrctl.bat)', True);
    Exit;
  end;
  if not SameText(ActiveConfig(P), ConfigName) then
  begin
    Title(Format('selecione a configuração %s (Hot Reload > Ativar neste projeto, se ainda não existir)',
      [ConfigName]), True);
    Exit;
  end;
  Result := True;
end;

procedure TExpert.AddMenu;
var
  Main: TMainMenu;
  I, Pos: Integer;

  function Item(const Caption: string; Handler: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(FMenu);
    Result.Caption := Caption;
    Result.OnClick := Handler;
    FMenu.Add(Result);
  end;

var
  R: TRegistry;
begin
  Main := (BorlandIDEServices as INTAServices).MainMenu;
  FMenu := TMenuItem.Create(nil);
  FMenu.Caption := 'Hot &Reload';
  FMenu.Name := 'HotReloadMenu';
  Item('&Ativar neste projeto', DoActivate);
  Item('-', nil);
  Item('&Patch agora', DoPatchNow);
  Item('&Reiniciar (recompila e volta nas mesmas telas)', DoRestart);
  Item('-', nil);
  FAuto := Item('Patch automático ao &salvar', DoToggleAuto);
  FAuto.Checked := True;
  R := TRegistry.Create(KEY_READ);
  try
    if R.OpenKeyReadOnly(RegKey) and R.ValueExists('Auto') then
      FAuto.Checked := R.ReadBool('Auto');
  finally
    R.Free;
  end;
  // antes do menu Help (Ajuda), se achar; senão no fim
  Pos := Main.Items.Count;
  for I := 0 to Main.Items.Count - 1 do
    if SameText(Main.Items[I].Name, 'HelpMenu') then
    begin
      Pos := I;
      Break;
    end;
  Main.Items.Insert(Pos, FMenu);
end;

procedure TExpert.DoToggleAuto(Sender: TObject);
var
  R: TRegistry;
begin
  FAuto.Checked := not FAuto.Checked;
  R := TRegistry.Create;
  try
    if R.OpenKey(RegKey, True) then
      R.WriteBool('Auto', FAuto.Checked);
  finally
    R.Free;
  end;
  Title('patch automático ao salvar: ' + IfThen(FAuto.Checked, 'ligado', 'desligado'), True);
end;

{ Ativar }

procedure TExpert.DoActivate(Sender: TObject);
var
  P: IOTAProject;
  C: IOTAProjectOptionsConfigurations;
  Cfg, Rel: IOTABuildConfiguration;
  I: Integer;
  Ed: IOTASourceEditor;
  Rd: IOTAEditReader;
  Wr: IOTAEditWriter;
  Buf, Piece: RawByteString;
  Chunk: array[0..16383] of AnsiChar;
  N, Pos0: Integer;
  Text, Rel_, Units, Lower: string;
  UsesEnd, RunPos: Integer;
  Changed: Boolean;
const
  UnitNames: array[0..4] of string = ('HotReload.DfmModel', 'HotReload.DfmApply', 'HotReload.Patch',
    'HotReload.Control', 'HotReload');

  /// posição em bytes UTF-8 do caractere I (1-based) de Text
  function BytePos(I: Integer): Integer;
  begin
    Result := Length(UTF8Encode(Copy(Text, 1, I - 1)));
  end;

begin
  P := GetActiveProject;
  if P = nil then
  begin
    Title('nenhum projeto ativo', True);
    Exit;
  end;
  Changed := False;

  // 1. Build configuration HotReload, filha da Release.
  if Supports(P.ProjectOptions, IOTAProjectOptionsConfigurations, C) then
  begin
    Cfg := nil;
    Rel := nil;
    for I := 0 to C.ConfigurationCount - 1 do
    begin
      if SameText(C.Configurations[I].Name, ConfigName) then
        Cfg := C.Configurations[I];
      if SameText(C.Configurations[I].Name, 'Release') then
        Rel := C.Configurations[I];
    end;
    if Cfg = nil then
    begin
      if Rel = nil then
        Rel := C.BaseConfiguration;
      Cfg := C.AddConfiguration(ConfigName, Rel);
      Cfg.Value['DCC_Define'] := 'HOTRELOAD;$(DCC_Define)';
      Cfg.Value['DCC_MapFile'] := '3';
      Title('configuração HotReload criada (filha da Release, define HOTRELOAD, .map detalhado)', True);
      Changed := True;
    end
    else
      Title('a configuração HotReload já existe');
  end;

  // 2. .dpr: units e THotReload.Start([]) dentro de {$IFDEF HOTRELOAD}.
  Ed := nil;
  for I := 0 to P.ModuleFileCount - 1 do
    if SameText(ExtractFileExt(P.ModuleFileEditors[I].FileName), '.dpr') then
      Supports(P.ModuleFileEditors[I], IOTASourceEditor, Ed);
  if Ed <> nil then
  begin
    Rd := Ed.CreateReader;
    Buf := '';
    Pos0 := 0;
    repeat
      N := Rd.GetText(Pos0, PAnsiChar(@Chunk[0]), SizeOf(Chunk));
      if N > 0 then
      begin
        SetString(Piece, PAnsiChar(@Chunk[0]), N); // o buffer do editor é UTF-8, sem #0 no fim
        Buf := Buf + Piece;
        Inc(Pos0, N);
      end;
    until N < SizeOf(Chunk);
    Rd := nil;
    Text := UTF8ToString(Buf);
    Lower := LowerCase(Text);
    if Lower.Contains('hotreload in ') then
      Title('o .dpr já tem as units do hot reload')
    else
    begin
      UsesEnd := Lower.IndexOf(';', Lower.IndexOf('uses')) + 1; // 1-based do ';' do uses
      RunPos := Lower.LastIndexOf('application.run;') + 1;
      if RunPos = 0 then
        RunPos := Lower.LastIndexOf('end.') + 1;
      if (UsesEnd <= 0) or (RunPos <= 0) then
        Title('não achei o uses ou o Application.Run no .dpr; acrescente as units à mão', True)
      else
      begin
        Rel_ := ExtractRelativePath(IncludeTrailingPathDelimiter(ExtractFilePath(P.FileName)), SrcDir);
        Units := #13#10'  {$IFDEF HOTRELOAD},';
        for I := Low(UnitNames) to High(UnitNames) do
        begin
          Units := Units + #13#10'  ' + UnitNames[I] + ' in ''' + Rel_ + UnitNames[I] + '.pas''';
          if I < High(UnitNames) then
            Units := Units + ',';
        end;
        Units := Units + #13#10'  {$ENDIF}';
        // do fim para o começo, para as posições não andarem
        Wr := Ed.CreateUndoableWriter;
        Wr.CopyTo(BytePos(RunPos));
        Wr.Insert(PAnsiChar(UTF8Encode('{$IFDEF HOTRELOAD}'#13#10 +
          '  THotReload.Start([]); // pasta e comandos vêm do hotreload.ini gerado pelo hrctl setup'#13#10 +
          '  {$ENDIF}'#13#10'  ')));
        Wr := nil;
        Wr := Ed.CreateUndoableWriter;
        Wr.CopyTo(BytePos(UsesEnd));
        Wr.Insert(PAnsiChar(UTF8Encode(Units)));
        Wr := nil;
        Title('units do hot reload acrescentadas ao .dpr (de ' + Rel_ + ')', True);
        Changed := True;
      end;
    end;
  end;

  if Changed then
    P.Save(False, True); // o setup lê o .dproj do disco pelo msbuild

  // 3. Setup: comandos de build e hotreload.ini a partir das opções da IDE.
  FSetups.Remove(LowerCase(P.FileName));
  WithSetup(P,
    procedure(S: TSetupInfo)
    begin
      Title('pronto: selecione a configuração HotReload e rode (F9). Salvar um .pas aplica o patch.', True);
    end);
end;

{ Setup }

procedure TExpert.WithSetup(const P: IOTAProject; const Next: TProc<TSetupInfo>);
var
  Key, Dproj, Cfg: string;
  S: TSetupInfo;
  Stamp: TDateTime;
begin
  Dproj := P.FileName;
  Key := LowerCase(Dproj);
  Stamp := TFile.GetLastWriteTime(Dproj);
  if FSetups.TryGetValue(Key, S) and S.Valid and (S.Stamp = Stamp) then
  begin
    Next(S);
    Exit;
  end;
  Cfg := ActiveConfig(P);
  if not SameText(Cfg, ConfigName) then
    Cfg := ConfigName;
  Run('lendo as opções do projeto (hrctl setup)...',
    Format('"%s" setup --project "%s" --config %s --no-console', [HrctlPath, Dproj, Cfg]),
    procedure(Code: Integer; Output: TStrings)
    var
      L: string;
      V: TJSONValue;
      O: TJSONObject;
      Info: TSetupInfo;
    begin
      Info := Default(TSetupInfo);
      for L in Output do
        if L.StartsWith('RESULTADO ') then
        begin
          V := TJSONObject.ParseJSONValue(Copy(L, 11, MaxInt));
          try
            if V is TJSONObject then
            begin
              O := TJSONObject(V);
              Info.Exe := O.GetValue<string>('exe', '');
              Info.Make := O.GetValue<string>('make', '');
              Info.Patch := O.GetValue<string>('patch', '');
              Info.NewExe := O.GetValue<string>('newExe', '');
              Info.Valid := Info.Exe <> '';
              if not O.GetValue<Boolean>('map', True) then
                Title('aviso: a configuração não gera .map detalhado; o patch precisa dele', True);
            end;
          finally
            V.Free;
          end;
        end;
      if not Info.Valid then
      begin
        Title(Format('o hrctl setup falhou (código %d):', [Code]), True);
        for L in Output do
          if Trim(L) <> '' then
            Title('    ' + L);
        Exit;
      end;
      Info.Stamp := Stamp;
      FSetups.AddOrSetValue(Key, Info);
      Next(Info);
    end);
end;

{ Execução }

procedure TExpert.Run(const Caption, Command: string; const Done: TProc<Integer, TStrings>);
var
  Dir: string;
begin
  FBusy := True;
  Title(Caption);
  Dir := ExtractFileDir(HrctlPath);
  TThread.CreateAnonymousThread(
    procedure
    var
      Output: string;
      Code: Integer;
    begin
      try
        Code := Capture(Command, Dir, Output);
      except
        on E: Exception do
        begin
          Code := -1;
          Output := E.Message;
        end;
      end;
      TThread.Queue(nil,
        procedure
        begin
          Finished(Code, Output, Done);
        end);
    end).Start;
end;

/// Volta à thread principal ao fim de Run.
procedure Finished(Code: Integer; const Output: string; const Done: TProc<Integer, TStrings>);
var
  L: TStringList;
begin
  if GExpert = nil then
    Exit; // pacote descarregado enquanto rodava
  GExpert.FBusy := False;
  L := TStringList.Create;
  try
    L.Text := Output;
    Done(Code, L);
  finally
    L.Free;
  end;
  if GExpert.FPending.Count > 0 then
    GExpert.FTimer.Enabled := True; // salvou de novo enquanto compilava
end;

procedure TExpert.FileSaved(const FileName: string);
var
  P: IOTAProject;
  Key, H, Old: string;
begin
  if not FAuto.Checked or not SameText(ExtractFileExt(FileName), '.pas') or not FileExists(FileName) then
    Exit;
  P := GetActiveProject;
  if (P = nil) or not SameText(ActiveConfig(P), ConfigName) then
    Exit;
  Key := LowerCase(FileName);
  H := THashMD5.GetHashStringFromFile(FileName);
  if FHashes.TryGetValue(Key, Old) and (Old = H) then
    Exit; // só o .dfm mudou: o próprio exe aplica
  FHashes.AddOrSetValue(Key, H);
  FPending.Add(ExtractFileName(FileName));
  FTimer.Enabled := False;
  FTimer.Enabled := True;
end;

procedure TExpert.TimerTick(Sender: TObject);
var
  Names: string;
begin
  FTimer.Enabled := False;
  if FBusy then
    Exit; // Run religa o timer ao terminar
  Names := FPending.CommaText;
  FPending.Clear;
  if Names <> '' then
    StartPatch(Names + ' salvo');
end;

procedure TExpert.DoPatchNow(Sender: TObject);
begin
  StartPatch('pedido');
end;

procedure TExpert.StartPatch(const Reason: string);
var
  P: IOTAProject;
  T0: UInt64;
begin
  if FBusy then
  begin
    FPending.Add('?');
    Exit;
  end;
  if not ProjectReady(P) then
    Exit;
  T0 := GetTickCount64;
  WithSetup(P,
    procedure(S: TSetupInfo)
    begin
      Run(Reason + ': compilando o patch...',
        Format('"%s" --exe "%s" patch --build "%s" --new "%s"', [HrctlPath, S.Exe, S.Patch, S.NewExe]),
        procedure(Code: Integer; Output: TStrings)
        begin
          PatchDone(Code, Output, T0);
        end);
    end);
end;

procedure TExpert.ReportErrors(Output: TStrings; const ProjDir: string);
var
  L, F: string;
  M: TMatch;
begin
  for L in Output do
  begin
    M := TRegEx.Match(L, '^\s*(.+?)\((\d+)\)\s+(Error|Fatal|Warning):\s*(.*)$');
    if M.Success then
    begin
      F := M.Groups[1].Value;
      if ExtractFileDrive(F) = '' then
        F := ExpandFileName(IncludeTrailingPathDelimiter(ProjDir) + F);
      ToolMsg(F, M.Groups[3].Value + ': ' + M.Groups[4].Value, StrToIntDef(M.Groups[2].Value, 1));
    end
    else if (Pos('Fatal', L) > 0) or (Pos('Error', L) > 0) then
      Title('    ' + Trim(L));
  end;
end;

procedure TExpert.PatchDone(Code: Integer; Output: TStrings; T0: UInt64);
var
  L: string;
  P: IOTAProject;
begin
  case Code of
    0:
      begin
        Title(Format('código trocado sem reiniciar (%.1f s)', [(GetTickCount64 - T0) / 1000]), True);
        for L in Output do
          if L.Contains('alterada:') or L.Contains('nova:') or L.Contains('nenhuma rotina') then
            Title('    ' + Trim(L));
      end;
    2:
      Title('o exe não está rodando (rode o projeto na configuração HotReload)');
    4:
      begin
        Title('não compilou; nada foi aplicado', True);
        P := GetActiveProject;
        if P <> nil then
          ReportErrors(Output, ExtractFileDir(P.FileName));
      end;
    5:
      begin
        Title('a mudança mexe em estrutura: use Hot Reload > Reiniciar (as telas voltam abertas)', True);
        for L in Output do
          if L.Contains('nao da para trocar') then
            Title('    ' + Trim(L));
      end;
  else
    Title(Format('o patch falhou (código %d)', [Code]), True);
    for L in Output do
      if Trim(L) <> '' then
        Title('    ' + Trim(L));
  end;
end;

procedure TExpert.DoRestart(Sender: TObject);
var
  P: IOTAProject;
begin
  if FBusy then
  begin
    Title('aguarde: há um patch compilando');
    Exit;
  end;
  if not ProjectReady(P) then
    Exit;
  WithSetup(P,
    procedure(S: TSetupInfo)
    begin
      Run('reiniciando (compila, fecha e reabre nas mesmas telas)...',
        Format('"%s" --exe "%s" restart --build "%s"', [HrctlPath, S.Exe, S.Make]),
        procedure(Code: Integer; Output: TStrings)
        var
          L: string;
          Proj: IOTAProject;
        begin
          case Code of
            0:
              for L in Output do
                if L.StartsWith('reiniciado') then
                  Title(Trim(L), True);
            2:
              Title('o exe não está rodando', True);
            4:
              begin
                Title('não compilou; o exe continua aberto como estava', True);
                Proj := GetActiveProject;
                if Proj <> nil then
                  ReportErrors(Output, ExtractFileDir(Proj.FileName));
              end;
          else
            Title(Format('o reinício falhou (código %d)', [Code]), True);
            for L in Output do
              if Trim(L) <> '' then
                Title('    ' + Trim(L));
          end;
        end);
    end);
end;

procedure Register;
begin
  if GExpert = nil then
    GExpert := TExpert.Create(nil);
end;

initialization

finalization
  FreeAndNil(GExpert);

end.
