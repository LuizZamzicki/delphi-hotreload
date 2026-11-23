unit HotReload.Control;

(*
  Canal de controle para agentes: um named pipe dentro do exe de debug, usado pelo CLI
  tools\hrctl para ver e mexer nas telas sem print e sem navegar até elas.

  Pipe \\.\pipe\hotreload-<pid>-<exe>, modo mensagem. Uma conexão = um pedido JSON
  {"cmd": "...", "args": [...]} e uma resposta JSON {"ok": true|false, "error"?, "text"?, ...}.
  Os comandos rodam na thread principal (Synchronize). Os que podem abrir diálogo modal
  (click, close) só são enfileirados e respondem na hora; o efeito aparece em forms/log.

    ping                                 pid, exe, pastas vigiadas
    forms                                telas abertas e diálogos nativos do Windows
    dump <form> [componente] [--binary]  DFM da tela VIVA (estado atual, não o do disco)
    get <form> <caminho>                 get FormMain btnOk.Caption  |  get FormMain Caption
    set <form> <caminho> <valor>
    click <form> <componente>            TControl, TMenuItem, TBasicAction ou qualquer um com OnClick
    shot <form> <arquivo.png> [componente]
    reload <arquivo.dfm>                 aplica já e devolve o resultado
    open <TClasseForm>                   cria e mostra (Show) uma tela pela classe
    close <form>
    log [desde]                          linhas de log depois do número "desde"
    snapshot <arquivo.json>              salva telas abertas e o que foi digitado nelas
    quit                                 fecha o exe (Application.Terminate)
    patch <json> [--int3]                aplica um patch de código (nível 3, montado pelo hrctl)
    unpatch                              desfaz os patches de código

  <form> é o Name ou a classe da tela, ou "active".

  Reinício rápido (nível 2): o "hrctl restart" pede snapshot e quit, recompila e abre o exe
  de novo com HOTRELOAD_RESTORE=<arquivo.json>. Na partida, StartControlServer vê a variável
  e reabre as telas com posição, campos, checkboxes, abas e foco. O estado da restauração
  aparece no ping ("restore": nenhum | pendente | restaurado: N tela(s) | erro: ...).
*)

interface

/// Abre o pipe e, se HOTRELOAD_RESTORE estiver definida, agenda a restauração das telas.
procedure StartControlServer;
procedure StopControlServer;
function ControlPipeName: string;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON, System.TypInfo, System.Variants,
  System.IOUtils, System.StrUtils, System.Types, System.Generics.Collections, System.Generics.Defaults, System.DateUtils, Vcl.Controls, Vcl.Forms, Vcl.Graphics, Vcl.Menus, Vcl.StdCtrls,
  Vcl.ExtCtrls, Vcl.Imaging.pngimage, HotReload, HotReload.DfmModel, HotReload.DfmApply, HotReload.Patch;

type
  EControl = class(Exception);

  TControlServer = class(TThread)
  private
    FStopEvent: THandle;
    FIoEvent: THandle;
    function WaitIo(Pipe: THandle; var Ov: TOverlapped; TimeoutMs: DWORD; out Bytes: DWORD): Boolean;
    function ReadRequest(Pipe: THandle; out Request: string): Boolean;
    procedure WriteResponse(Pipe: THandle; const Response: string);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TControlAccess = class(TControl); // Click é protegido

function ConvertStringSecurityDescriptorToSecurityDescriptorW(StringSecurityDescriptor: PWideChar;
  StringSDRevision: DWORD; var SecurityDescriptor: Pointer; SecurityDescriptorSize: PULONG): BOOL; stdcall;
  external advapi32 name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';
function ConvertSidToStringSidW(Sid: PSID; var StringSid: PWideChar): BOOL; stdcall;
  external advapi32 name 'ConvertSidToStringSidW';

function PrintWindow(Wnd: HWND; DC: HDC; Flags: UINT): BOOL; stdcall; external user32 name 'PrintWindow';

var
  GServer: TControlServer;
  GPipeName: string;
  GStartDir: string;
  GRestoreState: string = 'nenhum';

function ControlPipeName: string;
begin
  if GPipeName = '' then
    GPipeName := Format('\\.\pipe\hotreload-%d-%s',
      [GetCurrentProcessId, ChangeFileExt(ExtractFileName(ParamStr(0)), '')]);
  Result := GPipeName;
end;

{ Ajudantes }

function Arg(const Args: TArray<string>; I: Integer; const What: string): string;
begin
  if (I > High(Args)) or Args[I].StartsWith('--') then
    raise EControl.CreateFmt('falta o argumento <%s>', [What]);
  Result := Args[I];
end;

function OptArg(const Args: TArray<string>; I: Integer): string;
begin
  if (I <= High(Args)) and not Args[I].StartsWith('--') then
    Result := Args[I]
  else
    Result := '';
end;

function HasFlag(const Args: TArray<string>; const Flag: string): Boolean;
var
  A: string;
begin
  for A in Args do
    if SameText(A, Flag) then
      Exit(True);
  Result := False;
end;

function FindForm(const Name: string): TCustomForm;
var
  I: Integer;
begin
  if SameText(Name, 'active') then
  begin
    Result := Screen.ActiveCustomForm;
    if Result = nil then
      raise EControl.Create('nenhuma tela ativa');
    Exit;
  end;
  for I := 0 to Screen.CustomFormCount - 1 do
    if SameText(Screen.CustomForms[I].Name, Name) or SameText(Screen.CustomForms[I].ClassName, Name) then
      Exit(Screen.CustomForms[I]);
  raise EControl.CreateFmt('a tela %s não está aberta (veja "forms")', [Name]);
end;

function FindComp(Form: TCustomForm; const Key: string): TComponent;
begin
  Result := FindComponentByKey(Form, Key);
  if Result = nil then
    raise EControl.CreateFmt('%s não tem o componente %s', [Form.Name, Key]);
end;

/// "pnlTopo.Font.Size": anda pelos componentes enquanto achar; o resto é propriedade.
procedure ResolvePath(Form: TCustomForm; const Path: string; out Obj: TObject; out Prop: string);
var
  Parts: TArray<string>;
  I: Integer;
  C, Next: TComponent;
  PI: PPropInfo;
begin
  Parts := Path.Split(['.']);
  C := Form;
  I := 0;
  while I < High(Parts) do
  begin
    Next := C.FindComponent(Parts[I]);
    if Next = nil then
      Break;
    C := Next;
    Inc(I);
  end;
  Obj := C;
  while I < High(Parts) do
  begin
    PI := GetPropInfo(Obj, Parts[I]);
    if (PI = nil) or (PI.PropType^.Kind <> tkClass) then
      raise EControl.CreateFmt('%s: %s não é componente nem propriedade-objeto de %s', [Path, Parts[I], Obj.ClassName]);
    Obj := GetObjectProp(Obj, PI);
    if Obj = nil then
      raise EControl.CreateFmt('%s: %s está vazio', [Path, Parts[I]]);
    Inc(I);
  end;
  Prop := Parts[High(Parts)];
  if GetPropInfo(Obj, Prop) = nil then
    raise EControl.CreateFmt('%s não tem a propriedade publicada %s', [Obj.ClassName, Prop]);
end;

function PropText(Obj: TObject; const Prop: string): string;
var
  PI: PPropInfo;
  O: TObject;
  M: TMethod;
begin
  PI := GetPropInfo(Obj, Prop);
  case PI.PropType^.Kind of
    tkClass:
      begin
        O := GetObjectProp(Obj, PI);
        if O = nil then
          Result := '(nil)'
        else if O is TStrings then
          Result := TStrings(O).Text
        else if (O is TComponent) and (TComponent(O).Name <> '') then
          Result := TComponent(O).Name
        else
          Result := '(' + O.ClassName + ')';
      end;
    tkMethod:
      begin
        M := GetMethodProp(Obj, PI);
        if M.Code = nil then
          Result := '(nil)'
        else if M.Data <> nil then
          Result := TObject(M.Data).MethodName(M.Code)
        else
          Result := '(?)';
      end;
  else
    Result := VarToStr(GetPropValue(Obj, Prop, True));
  end;
end;

procedure SetPropText(Form: TCustomForm; Obj: TObject; const Prop, Value: string);
var
  PI: PPropInfo;
  O: TObject;
  M: TMethod;
  C: TComponent;
begin
  PI := GetPropInfo(Obj, Prop);
  case PI.PropType^.Kind of
    tkClass:
      begin
        O := GetObjectProp(Obj, PI);
        if O is TStrings then
          TStrings(O).Text := Value
        else if GetTypeData(PI.PropType^).ClassType.InheritsFrom(TComponent) then
        begin
          C := nil;
          if (Value <> '') and not SameText(Value, 'nil') then
          begin
            C := FindComponentByKey(Form, Value);
            if C = nil then
              raise EControl.CreateFmt('%s não tem o componente %s', [Form.Name, Value]);
          end;
          SetObjectProp(Obj, PI, C);
        end
        else
          raise EControl.CreateFmt('não sei atribuir texto a %s (%s)', [Prop, GetTypeData(PI.PropType^).ClassType.ClassName]);
      end;
    tkMethod:
      begin
        M.Code := nil;
        M.Data := nil;
        if (Value <> '') and not SameText(Value, 'nil') then
        begin
          M.Code := Form.MethodAddress(Value);
          M.Data := Form;
          if M.Code = nil then
            raise EControl.CreateFmt('%s não tem o método publicado %s', [Form.ClassName, Value]);
        end;
        SetMethodProp(Obj, PI, M);
      end;
  else
    SetPropValue(Obj, Prop, Value);
  end;
end;

function LiveDfmText(Root: TComponent): string;
var
  Bin: TMemoryStream;
begin
  Bin := TMemoryStream.Create;
  try
    Bin.WriteComponent(Root);
    Bin.Position := 0;
    Result := DfmToCanonicalText(Bin);
  finally
    Bin.Free;
  end;
end;

/// Troca blocos binários (Picture.Data, Glyph.Data...) por um marcador: custam muitos
/// tokens e não dizem nada para quem lê.
procedure StripBinary(N: TDfmNode);
var
  I: Integer;
  P: TDfmProp;
  C: TDfmNode;
begin
  for I := 0 to N.Props.Count - 1 do
  begin
    P := N.Props[I];
    if P.Text.StartsWith(P.Name + ' = {') then
    begin
      P.Text := Format('%s = {...}  (binário omitido, %d linhas; use --binary)',
        [P.Name, Length(P.Text.Split([#13#10]))]);
      N.Props[I] := P;
    end;
  end;
  for C in N.Children do
    StripBinary(C);
end;

function EnumDialogChild(Wnd: HWND; Param: LPARAM): BOOL; stdcall;
var
  Buf: array[0..511] of Char;
  Cls: array[0..63] of Char;
begin
  if IsWindowVisible(Wnd) then
  begin
    GetClassName(Wnd, Cls, Length(Cls));
    GetWindowText(Wnd, Buf, Length(Buf));
    if (Buf[0] <> #0) and ((string(Cls) = 'Static') or (string(Cls) = 'Button')) then
      TStrings(Param).Add('    ' + string(Cls) + ': ' + string(Buf).Replace(#13#10, ' ').Replace(#10, ' '));
  end;
  Result := True;
end;

function EnumNativeDialog(Wnd: HWND; Param: LPARAM): BOOL; stdcall;
var
  Cls: array[0..63] of Char;
  Title: array[0..255] of Char;
begin
  if IsWindowVisible(Wnd) and (FindControl(Wnd) = nil) then
  begin
    GetClassName(Wnd, Cls, Length(Cls));
    if string(Cls) = '#32770' then
    begin
      GetWindowText(Wnd, Title, Length(Title));
      TStrings(Param).Add(Format('  diálogo nativo "%s"', [string(Title)]));
      EnumChildWindows(Wnd, @EnumDialogChild, Param);
    end;
  end;
  Result := True;
end;

{ Comandos }

procedure CmdPing(Resp: TJSONObject);
begin
  Resp.AddPair('text', Format('pid %d  %s'#13#10'pipe %s'#13#10'vigiando: %s'#13#10'restauração: %s'#13#10'patch de código: %d gancho(s)'#13#10,
    [GetCurrentProcessId, ParamStr(0), ControlPipeName, string.Join('; ', THotReload.WatchedDirs), GRestoreState, ActiveHooks]));
  // Campos para o "hrctl restart" reabrir o exe do mesmo jeito.
  Resp.AddPair('pid', TJSONNumber.Create(GetCurrentProcessId));
  Resp.AddPair('exe', ParamStr(0));
  Resp.AddPair('cmdline', string(GetCommandLine));
  Resp.AddPair('cwd', GStartDir);
  Resp.AddPair('restore', GRestoreState);
end;

{ Estado das telas (reinício rápido) }

const
  // Propriedades de "estado do usuário": o que ele mudou na tela, não o que o DFM define.
  StateProps: array[0..6] of string = ('Checked', 'ItemIndex', 'ActivePage', 'TabIndex', 'Position', 'Date', 'Time');

function IsDataAware(C: TComponent): Boolean;
begin
  // Mexer nesses alteraria o dataset; o dado volta quando a tela reabre a query.
  Result := (GetPropInfo(C, 'DataSource') <> nil) or (GetPropInfo(C, 'DataField') <> nil);
end;

procedure CollectState(Root: TComponent; const Prefix: string; Props: TJSONObject);
var
  I: Integer;
  C: TComponent;
  P, Key: string;
begin
  for I := 0 to Root.ComponentCount - 1 do
  begin
    C := Root.Components[I];
    if (C.Name = '') or IsDataAware(C) then
      Continue;
    Key := Prefix + C.Name;
    if (C is TCustomMemo) and (GetPropInfo(C, 'Lines') <> nil) then
      Props.AddPair(Key + '.Lines', PropText(C, 'Lines'))
    else if (C is TWinControl) and not (C is TButtonControl) and (GetPropInfo(C, 'Text') <> nil) then
      // TEdit, TComboBox, TcxTextEdit, TcxComboBox...: o que foi digitado
      Props.AddPair(Key + '.Text', PropText(C, 'Text'));
    for P in StateProps do
      if GetPropInfo(C, P) <> nil then
        Props.AddPair(Key + '.' + P, PropText(C, P));
    if C is TCustomFrame then
      CollectState(C, Key + '.', Props);
  end;
end;

function IsRestorable(F: TCustomForm): Boolean;
begin
  Result := (F.Name <> '') and not F.ClassNameIs('TMessageForm');
end;

/// Tela encaixada (ManualDock) numa aba de outro form, como muitos sistemas fazem com as telas
/// dentro do form principal: guarda onde estava, para encaixar igual na volta.
procedure AddDockInfo(F: TCustomForm; O: TJSONObject);
var
  Site, Page: TWinControl;
begin
  Site := F.HostDockSite;
  if (Site = nil) or (Site.Owner = nil) or (Site.Owner.Name = '') or (Site.Name = '') then
    Exit;
  O.AddPair('dockForm', Site.Owner.Name);
  O.AddPair('dockSite', Site.Name);
  Page := F.Parent;
  if (Page = nil) or (Page = Site) then
    Exit;
  // É comum guardar no Tag da aba o endereço do form (para fechar a aba certa); na volta, o novo.
  O.AddPair('pageTagIsForm', TJSONBool.Create(Page.Tag = NativeInt(F)));
  if GetPropInfo(Page, 'PageIndex') <> nil then
    O.AddPair('pageIndex', TJSONNumber.Create(GetOrdProp(Page, 'PageIndex')));
  if GetPropInfo(Site, 'ActivePage') <> nil then
    O.AddPair('activePage', TJSONBool.Create(GetObjectProp(Site, 'ActivePage') = Page));
end;

procedure CmdSnapshot(const Args: TArray<string>; Resp: TJSONObject);
var
  FileName: string;
  Root, O, Props: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  F: TCustomForm;
  Focus: string;
begin
  FileName := ExpandFileName(Arg(Args, 0, 'arquivo.json'));
  Root := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    Root.AddPair('forms', Arr);
    for I := 0 to Screen.CustomFormCount - 1 do // ordem de Z: a de cima primeiro
    begin
      F := Screen.CustomForms[I];
      if not IsRestorable(F) then
        Continue;
      O := TJSONObject.Create;
      Arr.AddElement(O);
      O.AddPair('name', F.Name);
      O.AddPair('class', F.ClassName);
      O.AddPair('left', TJSONNumber.Create(F.Left));
      O.AddPair('top', TJSONNumber.Create(F.Top));
      O.AddPair('width', TJSONNumber.Create(F.Width));
      O.AddPair('height', TJSONNumber.Create(F.Height));
      O.AddPair('maximized', TJSONBool.Create(F.WindowState = wsMaximized));
      O.AddPair('visible', TJSONBool.Create(F.Visible));
      O.AddPair('active', TJSONBool.Create(F = Screen.ActiveCustomForm));
      O.AddPair('modal', TJSONBool.Create(fsModal in F.FormState));
      Focus := '';
      if (F.ActiveControl <> nil) and (F.ActiveControl.Owner = F) then
        Focus := F.ActiveControl.Name;
      O.AddPair('focus', Focus);
      AddDockInfo(F, O);
      Props := TJSONObject.Create;
      O.AddPair('controls', Props);
      CollectState(F, '', Props);
    end;
    TFile.WriteAllText(FileName, Root.Format(2), TEncoding.UTF8);
    Resp.AddPair('text', Format('%s (%d tela(s))', [FileName, Arr.Count]));
  finally
    Root.Free;
  end;
end;

procedure CmdPatch(const Args: TArray<string>; Resp: TJSONObject);
var
  L: TStringList;
  Summary: string;
begin
  L := TStringList.Create;
  try
    Summary := ApplyPatch(Arg(Args, 0, 'json'), HasFlag(Args, '--int3'), L);
    THotReload.AddLog('patch de código: ' + Summary);
    Resp.AddPair('text', Summary + #13#10 + L.Text);
  finally
    L.Free;
  end;
end;

procedure CmdUnpatch(Resp: TJSONObject);
begin
  Resp.AddPair('text', Format('%d gancho(s) desfeito(s)', [RevertPatches]));
end;

procedure CmdQuit(Resp: TJSONObject);
begin
  TThread.ForceQueue(nil,
    procedure
    begin
      Application.Terminate;
    end);
  // Com uma tela modal aberta (um login, por exemplo), o Terminate só fecha o modal e o
  // programa pode seguir adiante. Se em 5 s ainda estiver no ar, encerra o processo.
  TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(5000);
      ExitProcess(0);
    end).Start;
  Resp.AddPair('text', 'fechando');
end;

function OpenFormForRestore(const AName, AClass: string): TCustomForm;
var
  I: Integer;
  Cls: TComponentClass;
begin
  for I := 0 to Screen.CustomFormCount - 1 do
    if SameText(Screen.CustomForms[I].Name, AName) then
      Exit(Screen.CustomForms[I]);
  for I := 0 to Screen.CustomFormCount - 1 do
    if Screen.CustomForms[I].ClassNameIs(AClass) then
      Exit(Screen.CustomForms[I]);
  Cls := FindComponentClassByName(AClass);
  if (Cls = nil) or not Cls.InheritsFrom(TCustomForm) then
    raise EControl.CreateFmt('classe %s não está no exe', [AClass]);
  Result := TCustomFormClass(Cls).Create(Application);
end;

function RestoreState(const FileName: string): Integer;
var
  V: TJSONValue;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
  F, Active: TCustomForm;
  Docked: TList<TJSONObject>;
  ActivePage: TWinControl;
  ActiveSite: TWinControl;

  function Open(O: TJSONObject): TCustomForm;
  begin
    try
      Result := OpenFormForRestore(O.GetValue<string>('name'), O.GetValue<string>('class'));
    except
      on E: Exception do
      begin
        THotReload.AddLog(Format('restaurar %s: %s', [O.GetValue<string>('name'), E.Message]));
        Result := nil;
      end;
    end;
  end;

  procedure ApplyControls(F: TCustomForm; O: TJSONObject);
  var
    Pair: TJSONPair;
    Obj: TObject;
    Prop, Focus: string;
    C: TComponent;
    Failed: Integer;
  begin
    Failed := 0;
    for Pair in O.GetValue('controls') as TJSONObject do
    try
      ResolvePath(F, Pair.JsonString.Value, Obj, Prop);
      SetPropText(F, Obj, Prop, Pair.JsonValue.Value);
    except
      Inc(Failed); // componente que saiu da tela ou mudou de tipo na versão nova
    end;
    Focus := O.GetValue<string>('focus');
    if Focus <> '' then
    begin
      C := F.FindComponent(Focus);
      if (C is TWinControl) and TWinControl(C).CanFocus then
        F.ActiveControl := TWinControl(C);
    end;
    if Failed > 0 then
      THotReload.AddLog(Format('restaurar %s: %d valor(es) não voltaram', [F.Name, Failed]));
  end;

  function FindSite(O: TJSONObject): TWinControl;
  var
    Host: TCustomForm;
    C: TComponent;
  begin
    Result := nil;
    try
      Host := FindForm(O.GetValue<string>('dockForm'));
    except
      Exit;
    end;
    C := Host.FindComponent(O.GetValue<string>('dockSite'));
    if C is TWinControl then
      Result := TWinControl(C);
  end;

  /// Mesmo caminho de um DockForm típico: ManualDock, maximiza, Show, Tag da aba, aba visível.
  procedure Dock(F: TCustomForm; O: TJSONObject; Site: TWinControl);
  var
    Page: TWinControl;
    Idx: Integer;
  begin
    F.ManualDock(Site, nil, alClient);
    if O.GetValue<Boolean>('maximized') then
      F.WindowState := wsMaximized;
    F.Show;
    Site.Visible := True;
    Page := F.Parent;
    if (Page = nil) or (Page = Site) then
      Exit;
    if O.GetValue<Boolean>('pageTagIsForm', False) then
      Page.Tag := NativeInt(F);
    Idx := O.GetValue<Integer>('pageIndex', -1);
    if (Idx >= 0) and (GetPropInfo(Page, 'PageIndex') <> nil) then
    try
      SetOrdProp(Page, 'PageIndex', Idx);
    except
      // menos abas que antes: fica no fim
    end;
    if O.GetValue<Boolean>('activePage', False) then
    begin
      ActivePage := Page;
      ActiveSite := Site;
    end;
  end;

begin
  Result := 0;
  Active := nil;
  ActivePage := nil;
  ActiveSite := nil;
  Docked := TList<TJSONObject>.Create;
  V := TJSONObject.ParseJSONValue(TFile.ReadAllText(FileName, TEncoding.UTF8));
  try
    if not (V is TJSONObject) then
      raise EControl.Create('arquivo de estado inválido');
    Arr := TJSONObject(V).GetValue('forms') as TJSONArray;
    if Arr = nil then
      Exit;
    // 1. Janelas soltas, de trás para frente: a que estava por cima é a última a aparecer.
    for I := Arr.Count - 1 downto 0 do
    begin
      O := Arr.Items[I] as TJSONObject;
      // Tela escondida não se recria: criar o form principal à mão, por exemplo, roda o
      // OnCreate dele de novo. Tela modal (login, diálogo) é o próprio programa que abre.
      if not O.GetValue<Boolean>('visible') then
        Continue;
      if O.GetValue<Boolean>('modal') then
      begin
        THotReload.AddLog(Format('restaurar %s: era modal, não reaberta', [O.GetValue<string>('name')]));
        Continue;
      end;
      if O.GetValue<string>('dockSite', '') <> '' then
      begin
        Docked.Add(O); // encaixadas depois, na ordem das abas
        Continue;
      end;
      F := Open(O);
      if F = nil then
        Continue;
      if not F.Visible then
        F.Show; // antes do SetBounds: poScreenCenter reposiciona ao mostrar
      F.SetBounds(O.GetValue<Integer>('left'), O.GetValue<Integer>('top'),
        O.GetValue<Integer>('width'), O.GetValue<Integer>('height'));
      if O.GetValue<Boolean>('maximized') then
        F.WindowState := wsMaximized;
      ApplyControls(F, O);
      if O.GetValue<Boolean>('active') then
        Active := F;
      Inc(Result);
    end;
    // 2. Encaixadas em abas, na ordem em que as abas estavam.
    Docked.Sort(TComparer<TJSONObject>.Construct(
      function(const A, B: TJSONObject): Integer
      begin
        Result := A.GetValue<Integer>('pageIndex', MaxInt) - B.GetValue<Integer>('pageIndex', MaxInt);
      end));
    for O in Docked do
    begin
      F := Open(O);
      if F = nil then
        Continue;
      if FindSite(O) <> nil then
        Dock(F, O, FindSite(O))
      else
      begin
        THotReload.AddLog(Format('restaurar %s: não achei %s.%s para encaixar; aberta solta',
          [F.Name, O.GetValue<string>('dockForm'), O.GetValue<string>('dockSite')]));
        F.Show;
      end;
      ApplyControls(F, O);
      Inc(Result);
    end;
    if (ActiveSite <> nil) and (GetPropInfo(ActiveSite, 'ActivePage') <> nil) then
      SetObjectProp(ActiveSite, 'ActivePage', ActivePage);
    if (Active <> nil) and Active.Visible then
      Active.BringToFront;
  finally
    V.Free;
    Docked.Free;
  end;
end;

type
  /// Espera o programa ficar pronto para reabrir as telas:
  ///  - as telas que estavam abertas como modal no snapshot (há sistemas cujo form principal
  ///    roda com ShowModal) existem e estão visíveis de novo, o que nesses sistemas só acontece
  ///    depois do login;
  ///  - nenhuma outra tela modal aberta (um login, um aviso);
  ///  - tudo isso por 1,5 s seguidos.
  /// As telas não modais não bloqueiam: é a própria restauração que vai abri-las (e o
  /// programa pode ter criado algumas escondidas na partida).
  /// Roda num timer, e não dentro de TThread.Queue: se uma tela reaberta abrir um modal, o
  /// canal continua respondendo.
  TRestorer = class(TComponent)
  private
    FFileName: string;
    FTimer: TTimer;
    FQuietSince: UInt64;
    FWaitFor: TArray<string>; // 'Name|Classe' das telas visíveis no snapshot
    FMustShow: TArray<string>; // ... e, delas, as que eram modais
    function InSnapshot(F: TCustomForm): Boolean;
    function UnexpectedModal: string;
    function WaitingForm: string;
    procedure Tick(Sender: TObject);
  public
    constructor Create(const AFileName: string); reintroduce;
  end;

var
  GRestorer: TRestorer;

constructor TRestorer.Create(const AFileName: string);
var
  V: TJSONValue;
  Item: TJSONValue;
  O: TJSONObject;
begin
  inherited Create(nil);
  FFileName := AFileName;
  try
    V := TJSONObject.ParseJSONValue(TFile.ReadAllText(AFileName, TEncoding.UTF8));
    try
      if (V is TJSONObject) and (TJSONObject(V).GetValue('forms') is TJSONArray) then
        for Item in TJSONArray(TJSONObject(V).GetValue('forms')) do
        begin
          O := Item as TJSONObject;
          if O.GetValue<Boolean>('visible') then
          begin
            FWaitFor := FWaitFor + [O.GetValue<string>('name') + '|' + O.GetValue<string>('class')];
            if O.GetValue<Boolean>('modal') then
              FMustShow := FMustShow + [O.GetValue<string>('name') + '|' + O.GetValue<string>('class')];
          end;
        end;
    finally
      V.Free;
    end;
  except
    FWaitFor := nil; // arquivo ruim: RestoreState reporta depois
  end;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 300;
  FTimer.OnTimer := Tick;
end;

function TRestorer.InSnapshot(F: TCustomForm): Boolean;
var
  W: string;
  P: Integer;
begin
  for W in FWaitFor do
  begin
    P := Pos('|', W);
    if SameText(F.Name, Copy(W, 1, P - 1)) or F.ClassNameIs(Copy(W, P + 1, MaxInt)) then
      Exit(True);
  end;
  Result := False;
end;

/// Tela modal aberta que não estava aberta no snapshot (um login, um aviso). Modal que já
/// estava lá (um form principal que roda com ShowModal) não conta.
function TRestorer.UnexpectedModal: string;
var
  I: Integer;
  F: TCustomForm;
begin
  for I := 0 to Screen.CustomFormCount - 1 do
  begin
    F := Screen.CustomForms[I];
    if F.Visible and (fsModal in F.FormState) and not InSnapshot(F) then
      Exit(IfThen(F.Name <> '', F.Name, F.ClassName));
  end;
  Result := '';
end;

/// Primeira tela que era modal no snapshot e ainda não existe ou não está visível aqui.
function TRestorer.WaitingForm: string;
var
  W: string;
  P, I: Integer;
  F: TCustomForm;
  Visible: Boolean;
begin
  for W in FMustShow do
  begin
    P := Pos('|', W);
    Visible := False;
    for I := 0 to Screen.CustomFormCount - 1 do
    begin
      F := Screen.CustomForms[I];
      if (SameText(F.Name, Copy(W, 1, P - 1)) or F.ClassNameIs(Copy(W, P + 1, MaxInt))) and F.Visible then
      begin
        Visible := True;
        Break;
      end;
    end;
    if not Visible then
      Exit(Copy(W, 1, P - 1));
  end;
  Result := '';
end;

procedure TRestorer.Tick(Sender: TObject);
var
  N: Integer;
  Waiting, Modal: string;
begin
  Waiting := WaitingForm;
  Modal := UnexpectedModal;
  if (Waiting <> '') or (Modal <> '') or (Screen.ActiveCustomForm = nil) then
  begin
    FQuietSince := 0;
    if Modal <> '' then
      GRestoreState := Format('aguardando: %s está aberta (ex.: login); as telas voltam depois dela', [Modal])
    else if Waiting <> '' then
      GRestoreState := Format('aguardando: %s ainda não apareceu (ex.: falta o login); as telas voltam depois', [Waiting])
    else
      GRestoreState := 'aguardando: nenhuma tela ativa';
    Exit;
  end;
  if FQuietSince = 0 then
    FQuietSince := GetTickCount64;
  if GetTickCount64 - FQuietSince < 1500 then
    Exit;
  FTimer.Enabled := False;
  try
    N := RestoreState(FFileName);
    GRestoreState := Format('restaurado: %d tela(s)', [N]);
  except
    on E: Exception do
      GRestoreState := 'erro: ' + E.Message;
  end;
  System.SysUtils.DeleteFile(FFileName); // estado de um restart só vale uma vez
  THotReload.AddLog(GRestoreState);
  GRestorer := nil;
  TThread.ForceQueue(nil,
    procedure
    begin
      Free;
    end);
end;

/// Onde o "hrctl restart" grava o estado. Serve quando o exe pede elevação: o Windows abre o
/// processo elevado sem herdar o ambiente, e a variável HOTRELOAD_RESTORE se perde.
function RestoreFileName: string;
begin
  Result := TPath.Combine(TPath.GetTempPath,
    'hotreload-restore-' + ChangeFileExt(ExtractFileName(ParamStr(0)), '') + '.json');
end;

procedure RestoreFromEnvironment;
var
  FileName: string;
begin
  FileName := GetEnvironmentVariable('HOTRELOAD_RESTORE');
  if FileName <> '' then
    SetEnvironmentVariable('HOTRELOAD_RESTORE', nil) // não passa para processos filhos
  else if TFile.Exists(RestoreFileName) and
    (SecondsBetween(Now, TFile.GetLastWriteTime(RestoreFileName)) <= 120) then
    FileName := RestoreFileName; // recente: veio de um restart agora
  if FileName = '' then
    Exit;
  GRestoreState := 'pendente';
  GRestorer := TRestorer.Create(FileName);
end;

procedure CmdForms(Resp: TJSONObject);
var
  L: TStringList;
  I: Integer;
  F: TCustomForm;
  Flags: string;
begin
  L := TStringList.Create;
  try
    for I := 0 to Screen.CustomFormCount - 1 do
    begin
      F := Screen.CustomForms[I];
      Flags := '';
      if F.Visible then Flags := Flags + ' visível';
      if F = Screen.ActiveCustomForm then Flags := Flags + ' ativa';
      if fsModal in F.FormState then Flags := Flags + ' modal';
      if (F.HostDockSite <> nil) and (F.HostDockSite.Owner <> nil) then
        Flags := Flags + Format(' encaixada em %s.%s', [F.HostDockSite.Owner.Name, F.HostDockSite.Name]);
      if F.Name <> '' then
        L.Add(Format('%s: %s "%s"%s %dx%d', [F.Name, F.ClassName, F.Caption, Flags, F.Width, F.Height]))
      else // diálogos do MessageDlg/ShowMessage não têm Name: endereçar pela classe
        L.Add(Format('%s (sem Name) "%s"%s %dx%d', [F.ClassName, F.Caption, Flags, F.Width, F.Height]));
    end;
    EnumThreadWindows(MainThreadID, @EnumNativeDialog, LPARAM(L));
    Resp.AddPair('text', L.Text);
  finally
    L.Free;
  end;
end;

procedure CmdDump(const Args: TArray<string>; Resp: TJSONObject);
var
  F: TCustomForm;
  Root, Node: TDfmNode;
  Key: string;
begin
  F := FindForm(Arg(Args, 0, 'form'));
  Root := ParseDfm(LiveDfmText(F));
  try
    Key := OptArg(Args, 1);
    Node := FindDfmNode(Root, Key);
    if Node = nil then
      raise EControl.CreateFmt('%s não tem o componente %s', [F.Name, Key]);
    if not HasFlag(Args, '--binary') then
      StripBinary(Node);
    Resp.AddPair('text', DfmNodeText(Node));
  finally
    Root.Free;
  end;
end;

procedure CmdGet(const Args: TArray<string>; Resp: TJSONObject);
var
  Obj: TObject;
  Prop: string;
begin
  ResolvePath(FindForm(Arg(Args, 0, 'form')), Arg(Args, 1, 'caminho'), Obj, Prop);
  Resp.AddPair('text', PropText(Obj, Prop));
end;

procedure CmdSet(const Args: TArray<string>; Resp: TJSONObject);
var
  F: TCustomForm;
  Obj: TObject;
  Prop: string;
begin
  F := FindForm(Arg(Args, 0, 'form'));
  ResolvePath(F, Arg(Args, 1, 'caminho'), Obj, Prop);
  if Length(Args) < 3 then
    raise EControl.Create('falta o argumento <valor>');
  SetPropText(F, Obj, Prop, Args[2]);
  Resp.AddPair('text', PropText(Obj, Prop));
end;

procedure DoClick(const FormName, Key: string);
var
  Target: TComponent;
begin
  try
    Target := FindComponentByKey(FindForm(FormName), Key);
    if Target is TControl then
      TControlAccess(Target).Click
    else if Target is TMenuItem then
      TMenuItem(Target).Click
    else if Target is TBasicAction then
      TBasicAction(Target).Execute
    else
      // Botões de barra (DevExpress TdxBar...) e afins: dispara o OnClick publicado
      TNotifyEvent(GetMethodProp(Target, 'OnClick'))(Target);
    THotReload.AddLog(Format('click em %s.%s: ok', [FormName, Key]));
  except
    on E: Exception do
      THotReload.AddLog(Format('click em %s.%s: %s: %s', [FormName, Key, E.ClassName, E.Message]));
  end;
end;

procedure CmdClick(const Args: TArray<string>; Resp: TJSONObject);
var
  FormName, Key: string;
  C: TComponent;
begin
  FormName := Arg(Args, 0, 'form');
  Key := Arg(Args, 1, 'componente');
  C := FindComp(FindForm(FormName), Key);
  if C is TControl then
  begin
    if not TControl(C).Visible then
      raise EControl.CreateFmt('%s está invisível', [Key]);
    if not TControl(C).Enabled then
      raise EControl.CreateFmt('%s está desabilitado', [Key]);
  end
  else if not ((C is TMenuItem) or (C is TBasicAction) or
    ((GetPropInfo(C, 'OnClick') <> nil) and (GetMethodProp(C, 'OnClick').Code <> nil))) then
    raise EControl.CreateFmt('%s (%s) não é clicável (sem OnClick)', [Key, C.ClassName]);
  // Enfileirado: se o clique abrir um diálogo modal, a resposta não fica presa nele.
  TThread.ForceQueue(nil,
    procedure
    begin
      DoClick(FormName, Key);
    end);
  Resp.AddPair('text', 'enfileirado; o efeito aparece em "forms" e "log"');
end;

procedure CmdShot(const Args: TArray<string>; Resp: TJSONObject);
var
  F: TCustomForm;
  FileName, Key: string;
  R: TRect;
  Full, Part: TBitmap;
  Png: TPngImage;
  C: TComponent;
  P: TPoint;
  Raw: TBitmap;
begin
  F := FindForm(Arg(Args, 0, 'form'));
  FileName := ExpandFileName(Arg(Args, 1, 'arquivo.png'));
  Key := OptArg(Args, 2);
  if not F.HandleAllocated or not IsWindowVisible(F.Handle) then
    raise EControl.CreateFmt('a tela %s não está visível', [F.Name]);
  GetWindowRect(F.Handle, R);
  Full := TBitmap.Create;
  Part := nil;
  Png := TPngImage.Create;
  try
    // PrintWindow só desenha num bitmap de 32 bits; num de 24 devolve True e deixa em branco.
    Raw := TBitmap.Create;
    try
      Raw.PixelFormat := pf32bit;
      Raw.SetSize(R.Width, R.Height);
      if not PrintWindow(F.Handle, Raw.Canvas.Handle, 2 {PW_RENDERFULLCONTENT}) then
        RaiseLastOSError;
      Full.PixelFormat := pf24bit; // sem canal alfa, senão o PNG sai transparente
      Full.SetSize(R.Width, R.Height);
      BitBlt(Full.Canvas.Handle, 0, 0, R.Width, R.Height, Raw.Canvas.Handle, 0, 0, SRCCOPY);
    finally
      Raw.Free;
    end;
    if Key <> '' then
    begin
      C := FindComp(F, Key);
      if not (C is TControl) then
        raise EControl.CreateFmt('%s não é um controle visual', [Key]);
      P := TControl(C).ClientToScreen(Point(0, 0));
      Part := TBitmap.Create;
      Part.PixelFormat := pf24bit;
      Part.SetSize(TControl(C).Width, TControl(C).Height);
      Part.Canvas.CopyRect(Rect(0, 0, Part.Width, Part.Height), Full.Canvas,
        Rect(P.X - R.Left, P.Y - R.Top, P.X - R.Left + Part.Width, P.Y - R.Top + Part.Height));
      Png.Assign(Part);
    end
    else
      Png.Assign(Full);
    ForceDirectories(ExtractFileDir(FileName));
    Png.SaveToFile(FileName);
    Resp.AddPair('text', Format('%s (%dx%d)', [FileName, Png.Width, Png.Height]));
  finally
    Png.Free;
    Part.Free;
    Full.Free;
  end;
end;

function LocateDfm(const Name: string): string;
var
  D: string;
  Found: TArray<string>;
begin
  if TFile.Exists(Name) then
    Exit(ExpandFileName(Name));
  for D in THotReload.WatchedDirs do
  begin
    Result := TPath.Combine(D, Name);
    if TFile.Exists(Result) then
      Exit;
    Found := TDirectory.GetFiles(D, ExtractFileName(Name), TSearchOption.soAllDirectories);
    if Length(Found) > 0 then
      Exit(Found[0]);
  end;
  raise EControl.CreateFmt('não achei %s (passe o caminho completo)', [Name]);
end;

procedure CmdReload(const Args: TArray<string>; Resp: TJSONObject);
var
  FileName: string;
  Msgs: TStringList;
  N: Integer;
begin
  FileName := LocateDfm(Arg(Args, 0, 'arquivo.dfm'));
  Msgs := TStringList.Create;
  try
    N := THotReload.ReloadFile(FileName, Msgs);
    Resp.AddPair('telas', TJSONNumber.Create(N));
    Resp.AddPair('text', Msgs.Text);
  finally
    Msgs.Free;
  end;
end;

procedure CmdOpen(const Args: TArray<string>; Resp: TJSONObject);
var
  Cls: TComponentClass;
  F: TCustomForm;
begin
  Cls := FindComponentClassByName(Arg(Args, 0, 'TClasseForm'));
  if (Cls = nil) or not Cls.InheritsFrom(TCustomForm) then
    raise EControl.CreateFmt('não há classe de tela %s no exe', [Args[0]]);
  F := TCustomFormClass(Cls).Create(Application);
  F.Show;
  Resp.AddPair('text', F.Name);
end;

procedure CmdClose(const Args: TArray<string>; Resp: TJSONObject);
var
  FormName: string;
begin
  FormName := Arg(Args, 0, 'form');
  FindForm(FormName);
  TThread.ForceQueue(nil,
    procedure
    begin
      try
        FindForm(FormName).Close;
      except
        on E: Exception do
          THotReload.AddLog(Format('close %s: %s', [FormName, E.Message]));
      end;
    end);
  Resp.AddPair('text', 'enfileirado');
end;

procedure CmdLog(const Args: TArray<string>; Resp: TJSONObject);
var
  L: TStringList;
  Last: Integer;
begin
  L := TStringList.Create;
  try
    Last := THotReload.LogSince(StrToIntDef(OptArg(Args, 0), 0), L);
    Resp.AddPair('ultimo', TJSONNumber.Create(Last));
    Resp.AddPair('text', L.Text);
  finally
    L.Free;
  end;
end;

procedure RunCommand(const Cmd: string; const Args: TArray<string>; Resp: TJSONObject);
begin
  if Cmd = 'ping' then CmdPing(Resp)
  else if Cmd = 'forms' then CmdForms(Resp)
  else if Cmd = 'dump' then CmdDump(Args, Resp)
  else if Cmd = 'get' then CmdGet(Args, Resp)
  else if Cmd = 'set' then CmdSet(Args, Resp)
  else if Cmd = 'click' then CmdClick(Args, Resp)
  else if Cmd = 'shot' then CmdShot(Args, Resp)
  else if Cmd = 'reload' then CmdReload(Args, Resp)
  else if Cmd = 'open' then CmdOpen(Args, Resp)
  else if Cmd = 'close' then CmdClose(Args, Resp)
  else if Cmd = 'log' then CmdLog(Args, Resp)
  else if Cmd = 'snapshot' then CmdSnapshot(Args, Resp)
  else if Cmd = 'quit' then CmdQuit(Resp)
  else if Cmd = 'patch' then CmdPatch(Args, Resp)
  else if Cmd = 'unpatch' then CmdUnpatch(Resp)
  else
    raise EControl.CreateFmt('comando desconhecido: "%s"', [Cmd]);
end;

/// Roda na thread principal.
function HandleRequest(const Request: string): string;
var
  V: TJSONValue;
  Req, Resp: TJSONObject;
  Arr: TJSONArray;
  Cmd: string;
  Args: TArray<string>;
  I: Integer;
begin
  Resp := TJSONObject.Create;
  try
    try
      V := TJSONObject.ParseJSONValue(Request);
      if not (V is TJSONObject) then
      begin
        V.Free;
        raise EControl.Create('o pedido não é um objeto JSON');
      end;
      Req := TJSONObject(V);
      try
        Cmd := LowerCase(Req.GetValue<string>('cmd', ''));
        Arr := Req.GetValue('args') as TJSONArray;
        if Arr <> nil then
        begin
          SetLength(Args, Arr.Count);
          for I := 0 to Arr.Count - 1 do
            Args[I] := Arr.Items[I].Value;
        end;
      finally
        Req.Free;
      end;
      Resp.AddPair('ok', TJSONBool.Create(True));
      RunCommand(Cmd, Args, Resp);
    except
      on E: Exception do
      begin
        Resp.Free;
        Resp := TJSONObject.Create;
        Resp.AddPair('ok', TJSONBool.Create(False));
        Resp.AddPair('error', E.Message);
      end;
    end;
    Result := Resp.ToJSON;
  finally
    Resp.Free;
  end;
end;

{ TControlServer }

constructor TControlServer.Create;
begin
  FStopEvent := CreateEvent(nil, True, False, nil);
  FIoEvent := CreateEvent(nil, True, False, nil);
  inherited Create(False);
end;

destructor TControlServer.Destroy;
begin
  Terminate;
  SetEvent(FStopEvent);
  if not Finished then
    WaitFor;
  inherited;
  CloseHandle(FIoEvent);
  CloseHandle(FStopEvent);
end;

/// Espera uma operação overlapped que devolveu ERROR_IO_PENDING. Parada ou timeout
/// cancelam a operação e devolvem False com ERROR_OPERATION_ABORTED.
function TControlServer.WaitIo(Pipe: THandle; var Ov: TOverlapped; TimeoutMs: DWORD; out Bytes: DWORD): Boolean;
var
  H: array[0..1] of THandle;
begin
  H[0] := FStopEvent;
  H[1] := Ov.hEvent;
  if WaitForMultipleObjects(2, @H[0], False, TimeoutMs) = WAIT_OBJECT_0 + 1 then
    Exit(GetOverlappedResult(Pipe, Ov, Bytes, False));
  CancelIo(Pipe);
  GetOverlappedResult(Pipe, Ov, Bytes, True);
  SetLastError(ERROR_OPERATION_ABORTED);
  Result := False;
end;

function TControlServer.ReadRequest(Pipe: THandle; out Request: string): Boolean;
var
  Ov: TOverlapped;
  Chunk: array[0..8191] of Byte;
  Data: TBytesStream;
  N, Err: DWORD;
  Ok: Boolean;
begin
  Data := TBytesStream.Create;
  try
    repeat
      FillChar(Ov, SizeOf(Ov), 0);
      Ov.hEvent := FIoEvent;
      ResetEvent(FIoEvent);
      N := 0;
      Err := 0;
      Ok := ReadFile(Pipe, Chunk, SizeOf(Chunk), N, @Ov);
      if not Ok and (GetLastError = ERROR_IO_PENDING) then
        Ok := WaitIo(Pipe, Ov, 5000, N)
      else
        // Em handle overlapped, o N do ReadFile não vale: o tamanho certo vem daqui, também
        // quando a leitura termina na hora com ERROR_MORE_DATA (pedido maior que 8 KB).
        Ok := GetOverlappedResult(Pipe, Ov, N, False);
      if not Ok then
        Err := GetLastError;
      if Ok or (Err = ERROR_MORE_DATA) then
        Data.WriteBuffer(Chunk, N);
    until Ok or (Err <> ERROR_MORE_DATA);
    Result := Ok;
    if Ok then
      Request := TEncoding.UTF8.GetString(Data.Bytes, 0, Data.Size);
  finally
    Data.Free;
  end;
end;

procedure TControlServer.WriteResponse(Pipe: THandle; const Response: string);
var
  Bytes: TBytes;
  Ov: TOverlapped;
  N: DWORD;
begin
  Bytes := TEncoding.UTF8.GetBytes(Response);
  FillChar(Ov, SizeOf(Ov), 0);
  Ov.hEvent := FIoEvent;
  ResetEvent(FIoEvent);
  if not WriteFile(Pipe, Bytes[0], Length(Bytes), N, @Ov) and (GetLastError = ERROR_IO_PENDING) then
    WaitIo(Pipe, Ov, 30000, N);
  FlushFileBuffers(Pipe); // só desconecta depois que o cliente leu
end;

function CurrentUserSid: string;
var
  Token: THandle;
  Buf: array[0..511] of Byte;
  Len: DWORD;
  S: PWideChar;
begin
  Result := '';
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Token) then
    Exit;
  try
    if GetTokenInformation(Token, TokenUser, @Buf, SizeOf(Buf), Len) and
      ConvertSidToStringSidW(PTokenUser(@Buf)^.User.Sid, S) then
    begin
      Result := S;
      LocalFree(HLOCAL(S));
    end;
  finally
    CloseHandle(Token);
  end;
end;

procedure TControlServer.Execute;
var
  Pipe: THandle;
  Ov: TOverlapped;
  N: DWORD;
  Connected: Boolean;
  Request, Response, Sddl, Sid: string;
  SD: Pointer;
  SA: TSecurityAttributes;
  PSA: PSecurityAttributes;
begin
  NameThreadForDebugging('HotReload.Control');
  // Exe que pede elevação (manifesto requireAdministrator) criaria o pipe só para
  // administradores, e o hrctl sem elevação levaria "acesso negado". Libera o próprio usuário.
  SD := nil;
  PSA := nil;
  Sddl := 'D:(A;;GA;;;SY)(A;;GA;;;BA)';
  Sid := CurrentUserSid;
  if Sid <> '' then
    Sddl := Sddl + '(A;;GA;;;' + Sid + ')';
  if ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(Sddl), 1, SD, nil) then
  begin
    SA.nLength := SizeOf(SA);
    SA.lpSecurityDescriptor := SD;
    SA.bInheritHandle := False;
    PSA := @SA;
  end;
  try
  while not Terminated do
  begin
    Pipe := CreateNamedPipe(PChar(ControlPipeName), PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_MESSAGE or PIPE_READMODE_MESSAGE or PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, PSA);
    if Pipe = INVALID_HANDLE_VALUE then
    begin
      Response := SysErrorMessage(GetLastError);
      TThread.Queue(nil,
        procedure
        begin
          THotReload.AddLog('canal de controle não abriu: ' + Response);
        end);
      Exit;
    end;
    try
      FillChar(Ov, SizeOf(Ov), 0);
      Ov.hEvent := FIoEvent;
      ResetEvent(FIoEvent);
      Connected := ConnectNamedPipe(Pipe, @Ov);
      if not Connected then
        case GetLastError of
          ERROR_PIPE_CONNECTED:
            Connected := True;
          ERROR_IO_PENDING:
            Connected := WaitIo(Pipe, Ov, INFINITE, N);
        end;
      if Terminated or not Connected then
        Continue;
      if ReadRequest(Pipe, Request) then
      begin
        Synchronize(
          procedure
          begin
            Response := HandleRequest(Request);
          end);
        WriteResponse(Pipe, Response);
      end;
    finally
      DisconnectNamedPipe(Pipe);
      CloseHandle(Pipe);
    end;
  end;
  finally
    if SD <> nil then
      LocalFree(HLOCAL(SD));
  end;
end;

procedure StartControlServer;
begin
  if GServer <> nil then
    Exit;
  GServer := TControlServer.Create;
  THotReload.AddLog('canal de controle: ' + ControlPipeName);
  RestoreFromEnvironment;
end;

procedure StopControlServer;
begin
  FreeAndNil(GServer);
end;

initialization
  GStartDir := GetCurrentDir; // antes que o programa troque de pasta

end.
