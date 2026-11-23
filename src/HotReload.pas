unit HotReload;

(*
  Hot reload de telas VCL, nível 1: layout (.dfm).

  Vigia as pastas de fonte e, quando um .dfm é salvo, reaplica nas telas abertas da mesma
  classe (ou de descendentes) só o que mudou; o resto da tela (texto digitado, registro
  posicionado, query aberta) fica como está. Telas abertas depois da mudança recebem o
  delta quando aparecem. O que é reaplicado e os limites estão em HotReload.DfmApply.

  Uso, no .dpr, depois de criar o form principal:
    {$IFDEF DEBUG}
    THotReload.Start(['C:\Fontes\MeuProjeto']);
    {$ENDIF}
  Sem pastas, usa a variável de ambiente HOTRELOAD_DIRS (separadas por ";").
*)

interface

uses
  System.SysUtils, System.Classes;

type
  THotReloadLog = reference to procedure(const Msg: string);

  THotReload = class
  public
    class var OnLog: THotReloadLog;
    /// Vigia as pastas e abre o canal de controle para agentes (HotReload.Control).
    class procedure Start(const Dirs: array of string);
    class procedure Stop;
    class function Active: Boolean;
    /// DFM de origem para uma classe que não tem DFM no exe (ou para forçar outro).
    class procedure RegisterBaseline(const AClassName, DfmText: string);
    /// Aplica já o .dfm nas telas abertas, mesmo sem mudança desde a última vez. Devolve
    /// quantas telas receberam o delta; Messages recebe o log dessa aplicação.
    class function ReloadFile(const FileName: string; Messages: TStrings): Integer;
    /// Linhas de log com número maior que Since ("número<TAB>hh:nn:ss mensagem"); devolve o último número.
    class function LogSince(Since: Integer; Lines: TStrings): Integer;
    class function WatchedDirs: TArray<string>;
    /// Escreve no log do hot reload (OutputDebugString, OnLog e o buffer do comando "log").
    /// Só na thread principal.
    class procedure AddLog(const Msg: string);
  end;

implementation

uses
  Winapi.Windows, System.Generics.Collections, System.Generics.Defaults, System.IniFiles,
  Vcl.Forms, Vcl.ExtCtrls, HotReload.DfmModel, HotReload.DfmApply, HotReload.Control;

type
  PFileNotify = ^TFileNotify;
  TFileNotify = record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD;
    FileName: array[0..0] of WideChar;
  end;

  /// Uma thread por pasta: junta os avisos do Windows, espera o arquivo "sossegar" e lê o
  /// DFM já normalizado fora da thread principal.
  TDirWatcher = class(TThread)
  private
    FDir: string;
    FStopEvent: THandle;
    procedure QueueLog(const Msg: string);
    procedure FileReady(const FileName: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const Dir: string);
    destructor Destroy; override;
  end;

  /// Vive na thread principal. Sabe o texto atual de cada .dfm mudado e o texto que cada
  /// tela aberta reflete, e aplica a diferença.
  TTracker = class(TComponent)
  private
    FFileText: TDictionary<string, string>;     // classe -> texto atual do .dfm em disco
    FInstanceText: TDictionary<string, string>; // 'ponteiro|classe' -> texto que a instância reflete
    FBaselines: TDictionary<string, string>;    // classe -> DFM de origem registrado à mão
    FSeen: TList<TComponent>;                   // telas já vistas (com FreeNotification)
    FWatchers: TObjectList<TDirWatcher>;
    FTimer: TTimer;
    procedure TimerTick(Sender: TObject);
    procedure Track(C: TComponent);
    procedure CollectRoots(C: TComponent; const DfmClass: string; List: TList<TComponent>);
    procedure AllRoots(const DfmClass: string; List: TList<TComponent>);
    procedure SyncNew(F: TComponent; Roots: TList<TComponent>);
    function BaselineFor(Instance: TComponent; const DfmClass: string; out Text: string): Boolean;
    procedure Sync(Instance: TComponent; const DfmClass: string);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create; reintroduce;
    destructor Destroy; override;
    procedure AddWatcher(const Dir: string);
    function DfmChanged(const FileName, Text: string; Force: Boolean = False): Integer;
  end;

const
  LogKeep = 500;

var
  GTracker: TTracker;
  GLogRing: TStringList; // só mexido na thread principal
  GLogSeq: Integer;
  GCapture: TStrings;

procedure Log(const Msg: string);
begin
  OutputDebugString(PChar('[HotReload] ' + Msg));
  if GLogRing = nil then
    GLogRing := TStringList.Create;
  Inc(GLogSeq);
  GLogRing.AddObject(IntToStr(GLogSeq) + #9 + FormatDateTime('hh:nn:ss', Now) + ' ' + Msg, TObject(GLogSeq));
  while GLogRing.Count > LogKeep do
    GLogRing.Delete(0);
  if GCapture <> nil then
    GCapture.Add(Msg);
  if Assigned(THotReload.OnLog) then
    THotReload.OnLog(Msg);
end;

function ClassChainHas(C: TClass; const AName: string; out Found: TClass): Boolean;
begin
  while C <> nil do
  begin
    if SameText(C.ClassName, AName) then
    begin
      Found := C;
      Exit(True);
    end;
    C := C.ClassParent;
  end;
  Found := nil;
  Result := False;
end;

function InstancePrefix(Instance: TComponent): string;
begin
  Result := IntToHex(NativeUInt(Instance), SizeOf(Pointer) * 2) + '|';
end;

function InstanceKey(Instance: TComponent; const DfmClass: string): string;
begin
  Result := InstancePrefix(Instance) + UpperCase(DfmClass);
end;

function IsWatchedFile(const RelName: string): Boolean;
var
  Up: string;
begin
  Up := UpperCase(RelName);
  Result := (ExtractFileExt(Up) = '.DFM') and (Pos('__HISTORY', Up) = 0) and (Pos('__RECOVERY', Up) = 0);
end;

{ TDirWatcher }

constructor TDirWatcher.Create(const Dir: string);
begin
  FDir := ExcludeTrailingPathDelimiter(Dir);
  FStopEvent := CreateEvent(nil, True, False, nil);
  inherited Create(False);
end;

destructor TDirWatcher.Destroy;
begin
  Terminate;
  SetEvent(FStopEvent);
  if not Finished then
    WaitFor;
  TThread.RemoveQueuedEvents(Self);
  inherited;
  CloseHandle(FStopEvent);
end;

procedure TDirWatcher.QueueLog(const Msg: string);
var
  S: string;
begin
  S := Msg;
  TThread.Queue(Self,
    procedure
    begin
      Log(S);
    end);
end;

procedure TDirWatcher.FileReady(const FileName: string);
var
  F, Text: string;
begin
  F := FileName;
  try
    Text := DfmFileToCanonicalText(F);
  except
    on E: Exception do
    begin
      QueueLog(Format('%s: não consegui ler (%s)', [ExtractFileName(F), E.Message]));
      Exit;
    end;
  end;
  TThread.Queue(Self,
    procedure
    begin
      if GTracker <> nil then
      try
        GTracker.DfmChanged(F, Text);
      except
        on E: Exception do
          Log(Format('%s: %s', [ExtractFileName(F), E.Message]));
      end;
    end);
end;

procedure TDirWatcher.Execute;
const
  Filter = FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_LAST_WRITE or FILE_NOTIFY_CHANGE_SIZE;
  QuietMs = 150; // a IDE grava o .dfm em mais de uma escrita
var
  Dir: THandle;
  Ov: TOverlapped;
  Buf: TBytes;
  Bytes, Timeout, Wait: DWORD;
  Handles: array[0..1] of THandle;
  Pending: TDictionary<string, UInt64>;
  Ready: TList<string>;
  Pair: TPair<string, UInt64>;
  Info: PFileNotify;
  Name: string;
  Now: UInt64;
  Armed: Boolean;

  function Arm: Boolean;
  begin
    ResetEvent(Ov.hEvent);
    Result := ReadDirectoryChangesW(Dir, @Buf[0], Length(Buf), True, Filter, nil, @Ov, nil);
    Armed := Result;
  end;

begin
  NameThreadForDebugging('HotReload.Watcher');
  Dir := CreateFile(PChar(FDir), FILE_LIST_DIRECTORY, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED, 0);
  if Dir = INVALID_HANDLE_VALUE then
  begin
    QueueLog(Format('não consegui vigiar %s: %s', [FDir, SysErrorMessage(GetLastError)]));
    Exit;
  end;
  Armed := False;
  SetLength(Buf, 64 * 1024);
  FillChar(Ov, SizeOf(Ov), 0);
  Ov.hEvent := CreateEvent(nil, True, False, nil);
  Pending := TDictionary<string, UInt64>.Create(TIStringComparer.Ordinal);
  Ready := TList<string>.Create;
  try
    Handles[0] := FStopEvent;
    Handles[1] := Ov.hEvent;
    if not Arm then
    begin
      QueueLog(Format('não consegui vigiar %s: %s', [FDir, SysErrorMessage(GetLastError)]));
      Exit;
    end;
    while not Terminated do
    begin
      if Pending.Count > 0 then
        Timeout := 50
      else
        Timeout := INFINITE;
      Wait := WaitForMultipleObjects(2, @Handles[0], False, Timeout);
      if Wait = WAIT_OBJECT_0 then
        Break;
      if Wait = WAIT_OBJECT_0 + 1 then
      begin
        Armed := False;
        if GetOverlappedResult(Dir, Ov, Bytes, False) and (Bytes > 0) then
        begin
          Info := @Buf[0];
          while True do
          begin
            SetString(Name, PWideChar(@Info^.FileName[0]), Info^.FileNameLength div SizeOf(WideChar));
            case Info^.Action of
              FILE_ACTION_ADDED, FILE_ACTION_MODIFIED, FILE_ACTION_RENAMED_NEW_NAME:
                if IsWatchedFile(Name) then
                  Pending.AddOrSetValue(FDir + '\' + Name, GetTickCount64);
            end;
            if Info^.NextEntryOffset = 0 then
              Break;
            Info := PFileNotify(PByte(Info) + Info^.NextEntryOffset);
          end;
        end;
        if not Arm then
          Break;
      end;
      Now := GetTickCount64;
      Ready.Clear;
      for Pair in Pending do
        if Now - Pair.Value >= QuietMs then
          Ready.Add(Pair.Key);
      for Name in Ready do
      begin
        Pending.Remove(Name);
        FileReady(Name);
      end;
    end;
  finally
    if Armed then
    begin
      CancelIo(Dir);
      GetOverlappedResult(Dir, Ov, Bytes, True); // o buffer só pode sumir depois disso
    end;
    CloseHandle(Ov.hEvent);
    CloseHandle(Dir);
    Ready.Free;
    Pending.Free;
  end;
end;

{ TTracker }

constructor TTracker.Create;
begin
  inherited Create(nil);
  FFileText := TDictionary<string, string>.Create(TIStringComparer.Ordinal);
  FInstanceText := TDictionary<string, string>.Create;
  FBaselines := TDictionary<string, string>.Create(TIStringComparer.Ordinal);
  FSeen := TList<TComponent>.Create;
  FWatchers := TObjectList<TDirWatcher>.Create(True);
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 500;
  FTimer.OnTimer := TimerTick;
end;

destructor TTracker.Destroy;
begin
  FreeAndNil(FTimer);
  FreeAndNil(FWatchers); // cada watcher para e espera a própria thread
  FreeAndNil(FSeen);
  FreeAndNil(FBaselines);
  FreeAndNil(FInstanceText);
  FreeAndNil(FFileText);
  inherited;
end;

procedure TTracker.AddWatcher(const Dir: string);
begin
  FWatchers.Add(TDirWatcher.Create(Dir));
  Log('vigiando ' + Dir);
end;

procedure TTracker.Notification(AComponent: TComponent; Operation: TOperation);
var
  Prefix, K: string;
  Dead: TList<string>;
begin
  inherited;
  if (Operation <> opRemove) or (FSeen = nil) then
    Exit;
  if FSeen.Remove(AComponent) < 0 then
    Exit;
  Prefix := InstancePrefix(AComponent);
  Dead := TList<string>.Create;
  try
    for K in FInstanceText.Keys do
      if K.StartsWith(Prefix) then
        Dead.Add(K);
    for K in Dead do
      FInstanceText.Remove(K);
  finally
    Dead.Free;
  end;
end;

procedure TTracker.Track(C: TComponent);
begin
  if FSeen.IndexOf(C) < 0 then
  begin
    FSeen.Add(C);
    C.FreeNotification(Self);
  end;
end;

procedure TTracker.CollectRoots(C: TComponent; const DfmClass: string; List: TList<TComponent>);
var
  I: Integer;
  Found: TClass;
begin
  if ClassChainHas(C.ClassType, DfmClass, Found) then
    List.Add(C);
  for I := 0 to C.ComponentCount - 1 do
    if C.Components[I] is TCustomFrame then
      CollectRoots(C.Components[I], DfmClass, List);
end;

procedure TTracker.AllRoots(const DfmClass: string; List: TList<TComponent>);
var
  I: Integer;
begin
  for I := 0 to Screen.CustomFormCount - 1 do
    CollectRoots(Screen.CustomForms[I], DfmClass, List);
  for I := 0 to Screen.DataModuleCount - 1 do
    CollectRoots(Screen.DataModules[I], DfmClass, List);
end;

function TTracker.BaselineFor(Instance: TComponent; const DfmClass: string; out Text: string): Boolean;
var
  Found: TClass;
begin
  Result := FBaselines.TryGetValue(DfmClass, Text);
  if not Result and ClassChainHas(Instance.ClassType, DfmClass, Found) then
    Result := DfmResourceText(Found, Text);
end;

procedure TTracker.Sync(Instance: TComponent; const DfmClass: string);
var
  NewText, Cur, K: string;
  T0: UInt64;
begin
  if not FFileText.TryGetValue(DfmClass, NewText) then
    Exit;
  Track(Instance);
  K := InstanceKey(Instance, DfmClass);
  if not FInstanceText.TryGetValue(K, Cur) then
    if not BaselineFor(Instance, DfmClass, Cur) then
    begin
      Log(Format('%s: não achei o DFM de origem de %s no exe; ignorando', [Instance.Name, DfmClass]));
      FInstanceText.AddOrSetValue(K, NewText);
      Exit;
    end;
  if Cur = NewText then
  begin
    FInstanceText.AddOrSetValue(K, NewText);
    Exit;
  end;
  Log(Format('%s (%s): aplicando', [Instance.Name, DfmClass]));
  T0 := GetTickCount64;
  try
    ApplyDfmText(Instance, Cur, NewText, Log);
    FInstanceText.AddOrSetValue(K, NewText);
    Log(Format('  pronto em %d ms', [GetTickCount64 - T0]));
  except
    on E: Exception do
      Log('  erro: ' + E.Message);
  end;
end;

function TTracker.DfmChanged(const FileName, Text: string; Force: Boolean): Integer;
var
  Cls, Prev: string;
  Roots: TList<TComponent>;
  R: TComponent;
begin
  Result := 0;
  Cls := DfmHeaderClassName(Text);
  if Cls = '' then
    raise EParserError.CreateFmt('%s não começa com object/inherited/inline', [ExtractFileName(FileName)]);
  if not Force and FFileText.TryGetValue(Cls, Prev) and (Prev = Text) then
    Exit; // salvou sem mudar nada
  FFileText.AddOrSetValue(Cls, Text);
  Roots := TList<TComponent>.Create;
  try
    AllRoots(Cls, Roots);
    if Roots.Count = 0 then
      Log(Format('%s salvo; nenhuma %s aberta (aplica quando abrir)', [ExtractFileName(FileName), Cls]));
    for R in Roots do
      Sync(R, Cls);
    Result := Roots.Count;
  finally
    Roots.Free;
  end;
end;

procedure TTracker.SyncNew(F: TComponent; Roots: TList<TComponent>);
var
  Cls: string;
  R: TComponent;
begin
  if FSeen.IndexOf(F) >= 0 then
    Exit;
  Track(F);
  for Cls in FFileText.Keys do
  begin
    Roots.Clear;
    CollectRoots(F, Cls, Roots);
    for R in Roots do
      Sync(R, Cls);
  end;
end;

procedure TTracker.TimerTick(Sender: TObject);
var
  I: Integer;
  Roots: TList<TComponent>;
begin
  // Tela criada depois da mudança nasceu com o DFM antigo do exe: aplica o delta nela.
  if FFileText.Count = 0 then
    Exit;
  Roots := TList<TComponent>.Create;
  try
    for I := 0 to Screen.CustomFormCount - 1 do
      SyncNew(Screen.CustomForms[I], Roots);
    for I := 0 to Screen.DataModuleCount - 1 do
      SyncNew(Screen.DataModules[I], Roots);
  finally
    Roots.Free;
  end;
end;

{ Console do hrctl watch }

/// Mesmo nome que o hrctl watch cria (NomeMutexWatch no hrctl.dpr).
function WatchMutexName(const Dir: string): string;
var
  C: Char;
begin
  Result := 'Local\hrctl-watch-';
  for C in LowerCase(ExcludeTrailingPathDelimiter(Dir)) do
    if CharInSet(C, ['a'..'z', '0'..'9']) then
      Result := Result + C
    else
      Result := Result + '_';
end;

(* Abre o console do "hrctl watch" (modo para humanos) quando há um hotreload.ini ao lado do
   exe com auto=1, a menos que já haja um vigiando a mesma pasta ou que HOTRELOAD_NOWATCH esteja
   definida (agentes: o watch aplicaria patch sozinho enquanto o agente edita). Caminhos
   relativos valem a partir da pasta do exe.

     [watch]
     auto=1
     hrctl=C:\delphi-hotreload\tools\hrctl\bin\hrctl.exe
     dir=C:\fonte\do\projeto
     patch_build=C:\...\patch.bat
     new=C:\...\patch\Projeto.exe
     build=C:\...\make.bat
     auto_restart=0 *)
procedure StartWatchConsole;
var
  Ini: TIniFile;
  ExeDir, Hrctl, Dir, Cmd: string;
  M: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;

  function Full(const S: string): string;
  begin
    if S = '' then
      Result := ''
    else if ExtractFileDrive(S) <> '' then
      Result := S
    else
      Result := ExpandFileName(ExeDir + S);
  end;

begin
  if GetEnvironmentVariable('HOTRELOAD_NOWATCH') <> '' then
    Exit;
  ExeDir := ExtractFilePath(ParamStr(0));
  if not FileExists(ExeDir + 'hotreload.ini') then
    Exit;
  Ini := TIniFile.Create(ExeDir + 'hotreload.ini');
  try
    if not Ini.ReadBool('watch', 'auto', False) then
      Exit;
    Hrctl := Full(Ini.ReadString('watch', 'hrctl', ''));
    Dir := ExcludeTrailingPathDelimiter(Full(Ini.ReadString('watch', 'dir', '')));
    Cmd := Format('"%s" watch --dir "%s" --patch-build "%s" --new "%s" --build "%s"',
      [Hrctl, Dir, Full(Ini.ReadString('watch', 'patch_build', '')),
       Full(Ini.ReadString('watch', 'new', '')), Full(Ini.ReadString('watch', 'build', ''))]);
    if Ini.ReadBool('watch', 'auto_restart', False) then
      Cmd := Cmd + ' --auto-restart';
  finally
    Ini.Free;
  end;
  if not FileExists(Hrctl) or not DirectoryExists(Dir) then
  begin
    Log('hotreload.ini: hrctl ou dir não existe; console do watch não aberto');
    Exit;
  end;
  M := OpenMutex(SYNCHRONIZE, False, PChar(WatchMutexName(Dir)));
  if M <> 0 then
  begin
    CloseHandle(M); // já tem um watch (o restart reabre o exe com ele aberto)
    Exit;
  end;
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  UniqueString(Cmd);
  if CreateProcess(nil, PChar(Cmd), nil, nil, False, CREATE_NEW_CONSOLE, nil, PChar(Dir), SI, PI) then
  begin
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
    Log('console do hrctl watch aberto');
  end
  else
    Log('não consegui abrir o hrctl watch: ' + SysErrorMessage(GetLastError));
end;

/// Pasta do fonte a vigiar, do [watch] dir= do hotreload.ini ao lado do exe.
function IniWatchDirs: TArray<string>;
var
  Ini: TIniFile;
  F, D: string;
begin
  Result := nil;
  F := ExtractFilePath(ParamStr(0)) + 'hotreload.ini';
  if not FileExists(F) then
    Exit;
  Ini := TIniFile.Create(F);
  try
    D := Ini.ReadString('watch', 'dir', '');
  finally
    Ini.Free;
  end;
  if D <> '' then
  begin
    if ExtractFileDrive(D) = '' then
      D := ExpandFileName(ExtractFilePath(ParamStr(0)) + D);
    Result := [D];
  end;
end;

{ THotReload }

class procedure THotReload.Start(const Dirs: array of string);
var
  List: TArray<string>;
  D, Full: string;
  I: Integer;
begin
  if Length(Dirs) > 0 then
  begin
    SetLength(List, Length(Dirs));
    for I := 0 to High(Dirs) do
      List[I] := Dirs[I];
  end
  else
    List := GetEnvironmentVariable('HOTRELOAD_DIRS').Split([';'], TStringSplitOptions.ExcludeEmpty);
  if Length(List) = 0 then
    List := IniWatchDirs; // gerado pelo "hrctl setup" / plugin da IDE: sem caminho fixo no .dpr
  if GTracker = nil then
    GTracker := TTracker.Create;
  StartControlServer;
  if Length(List) = 0 then
    Log('nenhuma pasta para vigiar (passe em Start ou em HOTRELOAD_DIRS); só o canal de controle está ativo');
  for D in List do
  begin
    Full := ExpandFileName(Trim(D));
    if DirectoryExists(Full) then
      GTracker.AddWatcher(Full)
    else
      Log('pasta não existe: ' + Full);
  end;
  StartWatchConsole;
end;

class procedure THotReload.Stop;
begin
  StopControlServer;
  FreeAndNil(GTracker);
end;

class function THotReload.ReloadFile(const FileName: string; Messages: TStrings): Integer;
var
  Text: string;
begin
  Text := DfmFileToCanonicalText(FileName);
  if GTracker = nil then
    GTracker := TTracker.Create;
  GCapture := Messages;
  try
    Result := GTracker.DfmChanged(FileName, Text, True);
  finally
    GCapture := nil;
  end;
end;

class function THotReload.LogSince(Since: Integer; Lines: TStrings): Integer;
var
  I: Integer;
begin
  if GLogRing <> nil then
    for I := 0 to GLogRing.Count - 1 do
      if Integer(GLogRing.Objects[I]) > Since then
        Lines.Add(GLogRing[I]);
  Result := GLogSeq;
end;

class procedure THotReload.AddLog(const Msg: string);
begin
  Log(Msg);
end;

class function THotReload.WatchedDirs: TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  if GTracker = nil then
    Exit;
  SetLength(Result, GTracker.FWatchers.Count);
  for I := 0 to GTracker.FWatchers.Count - 1 do
    Result[I] := GTracker.FWatchers[I].FDir;
end;

class function THotReload.Active: Boolean;
begin
  Result := GTracker <> nil;
end;

class procedure THotReload.RegisterBaseline(const AClassName, DfmText: string);
begin
  if GTracker = nil then
    GTracker := TTracker.Create;
  GTracker.FBaselines.AddOrSetValue(AClassName, DfmText);
end;

initialization

finalization
  THotReload.Stop;
  FreeAndNil(GLogRing);

end.
