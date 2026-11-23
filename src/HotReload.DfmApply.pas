unit HotReload.DfmApply;

{
  Aplica numa tela viva a diferença entre dois DFMs (ver HotReload.DfmModel).

  O delta vira binário e é lido por um TReader próprio (THotReader) direto na instância que
  já existe. Componentes que existem vêm marcados como "inherited", então o leitor os procura
  com FindComponent em vez de criar; os novos vêm como "object" e são criados. Não usamos
  ReadRootComponent porque ele renomeia a raiz para um nome livre (Form1 viraria Form1_1).

  O que o TReader não sabe fazer fica com as operações do delta:
    - componente que saiu do DFM: Free (o campo publicado do form vira nil sozinho);
    - propriedade que saiu do DFM: volta ao padrão, copiado de uma instância nova da classe;
    - componente que trocou de pai: Parent := novo pai.

  Posições e tamanhos que mudaram são convertidos para o valor em execução antes de aplicar
  (ver AdjustToRuntime): a tela viva já foi escalada para o DPI do monitor e reposicionada por
  âncoras/alinhamento, e o DFM está em coordenadas de design.

  Limites conhecidos: componente cuja classe não está linkada no exe não pode ser criado (classe usada como
  campo em qualquer form está; uma citada só num "is" pode não estar); evento que aponta
  para método ainda não compilado fica como estava (avisa no log).
}

interface

uses
  System.SysUtils, System.Classes;

type
  TDfmLogProc = reference to procedure(const Msg: string);

/// Aceita DFM texto (ANSI ou UTF-8), binário 'TPF0' ou binário com cabeçalho de recurso.
function DfmToCanonicalText(Stream: TStream): string;
function DfmFileToCanonicalText(const FileName: string): string;
/// DFM compilado no exe para a classe (recurso RCDATA com o nome da classe).
function DfmResourceText(AClass: TClass; out Text: string): Boolean;
function FindComponentByKey(Root: TComponent; const Key: string): TComponent;
/// Classe de componente pelo nome: registradas e, se não achar, todas as linkadas no exe.
function FindComponentClassByName(const AName: string): TComponentClass;
/// Devolve False quando não havia nada para aplicar. Exceção = DFM inválido ou de outra classe.
function ApplyDfmText(Root: TComponent; const OldText, NewText: string; const Log: TDfmLogProc): Boolean;

implementation

uses
  Winapi.Windows, System.TypInfo, System.Generics.Collections, System.Generics.Defaults,
  Vcl.Controls, Vcl.Forms, HotReload.DfmModel;

{ Leitura e normalização }

function DfmToCanonicalText(Stream: TStream): string;
var
  Sig: array[0..3] of Byte;
  Start: Int64;
  Bin, Txt: TMemoryStream;
  Bytes: TBytes;
begin
  Bin := TMemoryStream.Create;
  Txt := TMemoryStream.Create;
  try
    Start := Stream.Position;
    FillChar(Sig, SizeOf(Sig), 0);
    Stream.Read(Sig, SizeOf(Sig));
    Stream.Position := Start;
    if Sig[0] = $FF then
    begin
      Stream.ReadResHeader;
      if Stream.Size > Stream.Position then
        Bin.CopyFrom(Stream, Stream.Size - Stream.Position);
    end
    else if (Sig[0] = Ord('T')) and (Sig[1] = Ord('P')) and (Sig[2] = Ord('F')) and (Sig[3] = Ord('0')) then
      Bin.CopyFrom(Stream, Stream.Size - Stream.Position)
    else
      ObjectTextToBinary(Stream, Bin);
    Bin.Position := 0;
    ObjectBinaryToText(Bin, Txt); // sai ASCII, acento como #nnn
    SetLength(Bytes, Txt.Size);
    if Txt.Size > 0 then
      Move(Txt.Memory^, Bytes[0], Txt.Size);
    Result := TEncoding.ANSI.GetString(Bytes);
  finally
    Txt.Free;
    Bin.Free;
  end;
end;

function DfmFileToCanonicalText(const FileName: string): string;
const
  Attempts = 20;
var
  Mem: TMemoryStream;
  FS: TFileStream;
  Attempt: Integer;
begin
  Mem := TMemoryStream.Create;
  try
    // A IDE pode estar com o arquivo aberto no instante do aviso de mudança.
    for Attempt := 1 to Attempts do
    try
      FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
      try
        Mem.Size := 0;
        Mem.CopyFrom(FS, 0);
      finally
        FS.Free;
      end;
      Break;
    except
      on EFOpenError do
      begin
        if Attempt = Attempts then
          raise;
        Sleep(50);
      end;
    end;
    Mem.Position := 0;
    Result := DfmToCanonicalText(Mem);
  finally
    Mem.Free;
  end;
end;

function DfmResourceText(AClass: TClass; out Text: string): Boolean;
var
  HInst: HMODULE;
  RS: TResourceStream;
begin
  HInst := FindResourceHInstance(FindClassHInstance(AClass));
  Result := FindResource(HInst, PChar(AClass.ClassName), RT_RCDATA) <> 0;
  if not Result then
    Exit;
  RS := TResourceStream.Create(HInst, AClass.ClassName, RT_RCDATA);
  try
    Text := DfmToCanonicalText(RS);
  finally
    RS.Free;
  end;
end;

function FindComponentByKey(Root: TComponent; const Key: string): TComponent;
var
  Part: string;
begin
  Result := Root;
  if Key = '' then
    Exit;
  for Part in Key.Split(['.']) do
  begin
    Result := Result.FindComponent(Part);
    if Result = nil then
      Exit;
  end;
end;

{ Classes de componente }

var
  GClassIndex: TDictionary<string, TComponentClass>;

/// Nome da classe se C for mesmo uma VMT de descendente de TComponent; '' se não for.
/// Cada VMT da cadeia precisa apontar para si mesma em vmtSelfPtr.
function ComponentClassName(C: TClass): string;
var
  X: TClass;
  Depth: Integer;
begin
  Result := '';
  try
    X := C;
    Depth := 0;
    while (X <> nil) and (Depth < 64) do
    begin
      if PPointer(PByte(X) + vmtSelfPtr)^ <> Pointer(X) then
        Exit;
      if X = TComponent then
        Exit(C.ClassName);
      X := X.ClassParent;
      Inc(Depth);
    end;
  except
    Result := '';
  end;
end;

/// Varre as seções do módulo atrás de VMTs: a posição P é o vmtSelfPtr de uma VMT quando
/// guarda o próprio endereço da VMT (P - vmtSelfPtr). Não depende de RTTI estendida, que
/// num exe sem runtime packages não lista todas as classes linkadas.
procedure IndexModuleClasses(Module: HMODULE);
var
  Nt: PImageNtHeaders;
  Sec: PImageSectionHeader;
  I: Integer;
  P, Stop: NativeInt;
  Size: DWORD;
  Name: string;
begin
  Nt := PImageNtHeaders(PByte(Module) + PImageDosHeader(Module)._lfanew);
  Sec := PImageSectionHeader(PByte(@Nt.OptionalHeader) + Nt.FileHeader.SizeOfOptionalHeader);
  for I := 0 to Nt.FileHeader.NumberOfSections - 1 do
  begin
    Size := Sec.Misc.VirtualSize;
    if Size = 0 then
      Size := Sec.SizeOfRawData;
    if (Sec.Characteristics and IMAGE_SCN_MEM_READ <> 0) and (Size >= SizeOf(Pointer)) then
    begin
      P := NativeInt(Module) + NativeInt(Sec.VirtualAddress);
      Stop := P + NativeInt(Size) - SizeOf(Pointer);
      while P <= Stop do
      begin
        if PNativeInt(P)^ = P - vmtSelfPtr then
        begin
          Name := ComponentClassName(TClass(P - vmtSelfPtr));
          if (Name <> '') and not GClassIndex.ContainsKey(Name) then
            GClassIndex.Add(Name, TComponentClass(P - vmtSelfPtr));
        end;
        Inc(P, SizeOf(Pointer));
      end;
    end;
    Inc(Sec);
  end;
end;

function IndexModule(HInstance: NativeInt; Data: Pointer): Boolean;
begin
  IndexModuleClasses(HMODULE(HInstance));
  Result := True;
end;

/// Componente novo cuja classe não é campo do form: procura nas registradas e, se não
/// achar, em todas as classes linkadas no exe e nos pacotes (índice montado uma vez só).
function FindComponentClassByName(const AName: string): TComponentClass;
var
  P: TPersistentClass;
begin
  P := GetClass(AName);
  if (P <> nil) and P.InheritsFrom(TComponent) then
    Exit(TComponentClass(P));
  if GClassIndex = nil then
  begin
    GClassIndex := TDictionary<string, TComponentClass>.Create(TIStringComparer.Ordinal);
    IndexModuleClasses(MainInstance); // o exe não vem garantido no EnumModules
    EnumModules(IndexModule, nil);    // runtime packages, quando houver
  end;
  if not GClassIndex.TryGetValue(AName, Result) then
    Result := nil;
end;

{ THotReader }

type
  THotReader = class(TReader)
  private
    FLog: TDfmLogProc;
    FMissingClass: string;
    procedure DoFindClass(Reader: TReader; const ClassName: string; var ComponentClass: TComponentClass);
  protected
    function Error(const Message: string): Boolean; override;
    function FindAncestorComponent(const Name: string; ComponentClass: TPersistentClass): TComponent; override;
    function FindMethod(Root: TComponent; const MethodName: string): Pointer; override;
  public
    constructor Create(Stream: TStream; const Log: TDfmLogProc);
    procedure ApplyTo(ARoot: TComponent);
  end;

constructor THotReader.Create(Stream: TStream; const Log: TDfmLogProc);
begin
  inherited Create(Stream, 4096);
  FLog := Log;
  OnFindComponentClass := DoFindClass;
end;

procedure THotReader.DoFindClass(Reader: TReader; const ClassName: string; var ComponentClass: TComponentClass);
begin
  ComponentClass := FindComponentClassByName(ClassName);
  if ComponentClass = nil then
  begin
    FLog(Format('  aviso: a classe %s não está no exe (procurei em %d classes); recompile para usar esse componente',
      [ClassName, GClassIndex.Count]));
    FMissingClass := ClassName;
  end;
end;

function THotReader.Error(const Message: string): Boolean;
begin
  // O "Class X not found" que vem logo depois repete o aviso de DoFindClass.
  if (FMissingClass <> '') and (Pos(FMissingClass, Message) > 0) then
    FMissingClass := ''
  else
    FLog('  aviso: ' + Message);
  Result := True; // pula a propriedade ou componente com problema e segue
end;

function THotReader.FindAncestorComponent(const Name: string; ComponentClass: TPersistentClass): TComponent;
begin
  // LookupRoot só é preenchido pelo próprio TReader ao entrar num frame inline; no nível da
  // raiz ele fica nil porque não passamos por ReadRootComponent.
  if LookupRoot <> nil then
    Result := LookupRoot.FindComponent(Name)
  else
    Result := Root.FindComponent(Name);
  if Result = nil then
    raise EReadError.CreateFmt('o componente %s não existe na tela aberta', [Name]);
end;

function THotReader.FindMethod(Root: TComponent; const MethodName: string): Pointer;
begin
  Result := Root.MethodAddress(MethodName);
  if Result = nil then
    FLog(Format('  aviso: o método %s não existe no %s compilado; o evento só liga depois de recompilar',
      [MethodName, Root.ClassName]));
end;

procedure THotReader.ApplyTo(ARoot: TComponent);
var
  Flags: TFilerFlags;
  ChildPos: Integer;
begin
  ReadSignature;
  ReadPrefix(Flags, ChildPos);
  ReadStr; // classe
  ReadStr; // nome: ignorado de propósito
  Root := ARoot;
  Owner := ARoot;
  Parent := ARoot;
  GlobalNameSpace.BeginWrite;
  try
    BeginReferences; // cria a lista de Loaded e de fixups
    try
      if ARoot is TWinControl then
        TWinControl(ARoot).DisableAlign;
      try
        ReadData(ARoot);
      finally
        if ARoot is TWinControl then
          TWinControl(ARoot).EnableAlign;
      end;
      FixupReferences; // resolve referências e chama Loaded dos componentes lidos
    finally
      EndReferences;
    end;
  finally
    GlobalNameSpace.EndWrite;
  end;
end;

{ Operações fora do TReader }

function TryReparent(Root: TComponent; const Op: TDfmOp): Boolean;
var
  Comp, NewParent: TComponent;
begin
  Comp := FindComponentByKey(Root, Op.Key);
  NewParent := FindComponentByKey(Root, Op.ParentKey);
  Result := (Comp is TControl) and (NewParent is TWinControl);
  if Result then
    TControl(Comp).Parent := TWinControl(NewParent);
end;

/// Instância "limpa" para copiar valores padrão. Para a raiz usa a classe base da VCL, porque
/// a classe do próprio form (TFormCliente) carregaria o DFM dela ao ser criada.
/// Propriedade de posição/tamanho que a VCL escala com o DPI (ScaleForPPI).
function IsScaledProp(const Name: string): Boolean;
const
  Last: array[0..10] of string = ('Left', 'Top', 'Width', 'Height', 'ClientWidth', 'ClientHeight',
    'MinWidth', 'MinHeight', 'MaxWidth', 'MaxHeight', 'Right');
var
  P: Integer;
  Seg, Prefix: string;
begin
  P := Name.LastIndexOf('.');
  Seg := Name.Substring(P + 1);
  if P < 0 then
    Prefix := ''
  else
    Prefix := Name.Substring(0, P);
  if (Prefix = '') or SameText(Prefix, 'Margins') or SameText(Prefix, 'Padding') or SameText(Prefix, 'Constraints') then
  begin
    for P := Low(Last) to High(Last) do
      if SameText(Seg, Last[P]) then
        Exit(True);
    Exit(SameText(Seg, 'ExplicitLeft') or SameText(Seg, 'ExplicitTop') or
      SameText(Seg, 'ExplicitWidth') or SameText(Seg, 'ExplicitHeight'));
  end;
  // Font.Height, Style.Font.Height (DevExpress)...
  Result := SameText(Seg, 'Height') and Prefix.EndsWith('Font', True);
end;

function PropIntValue(const Text: string; out V: Integer): Boolean;
var
  P: Integer;
begin
  P := Pos('=', Text);
  Result := (P > 0) and TryStrToInt(Trim(Copy(Text, P + 1, MaxInt)), V);
end;

/// Valor inteiro vivo por caminho ('Margins.Left', 'Style.Font.Height').
function LiveIntProp(Obj: TObject; const Path: string; out V: Integer): Boolean;
var
  Parts: TArray<string>;
  I: Integer;
  PI: PPropInfo;
begin
  Result := False;
  Parts := Path.Split(['.']);
  for I := 0 to High(Parts) do
  begin
    if Obj = nil then
      Exit;
    PI := GetPropInfo(Obj, Parts[I]);
    if PI = nil then
      Exit;
    if I < High(Parts) then
    begin
      if PI.PropType^.Kind <> tkClass then
        Exit;
      Obj := GetObjectProp(Obj, PI);
    end
    else
    begin
      if not (PI.PropType^.Kind in [tkInteger]) then
        Exit;
      V := GetOrdProp(Obj, PI);
      Result := True;
    end;
  end;
end;

/// Converte para o valor em execução as posições/tamanhos que mudaram no DFM:
///   execução = novo × escala + (vivo − antigo × escala)
/// A escala é o DPI atual sobre o de design (a VCL escala a tela ao carregar); a parcela entre
/// parênteses é quanto o controle já estava deslocado do DFM (âncoras numa tela maximizada ou
/// encaixada, alinhamento). Componente novo só recebe a escala.
procedure AdjustToRuntime(Root: TComponent; OldTree, NewTree: TDfmNode; M, D: Integer);

  procedure Walk(N: TDfmNode);
  var
    O, C: TDfmNode;
    Comp: TComponent;
    I, J, V, OV, Live, T: Integer;
    P: TDfmProp;
  begin
    O := FindDfmNode(OldTree, N.Key);
    if (O <> nil) and not SameText(O.TypeName, N.TypeName) then
      O := nil;
    Comp := nil;
    if O <> nil then
      Comp := FindComponentByKey(Root, N.Key);
    for I := 0 to N.Props.Count - 1 do
    begin
      P := N.Props[I];
      if not IsScaledProp(P.Name) or not PropIntValue(P.Text, V) then
        Continue;
      J := -1;
      if O <> nil then
      begin
        J := O.IndexOfProp(P.Name);
        if (J >= 0) and (O.Props[J].Text = P.Text) then
          Continue; // não mudou: fica fora do delta
      end;
      T := MulDiv(V, M, D);
      if (Comp <> nil) and (J >= 0) and PropIntValue(O.Props[J].Text, OV) and LiveIntProp(Comp, P.Name, Live) then
        T := T + (Live - MulDiv(OV, M, D));
      P.Text := P.Name + ' = ' + IntToStr(T);
      N.Props[I] := P;
    end;
    for C in N.Children do
      Walk(C);
  end;

begin
  Walk(NewTree);
end;

/// DPI de design: o que o DFM grava (PixelsPerInch, telas antigas) ou 96.
function DesignPPI(Tree: TDfmNode): Integer;
var
  J: Integer;
begin
  J := Tree.IndexOfProp('PixelsPerInch');
  if (J < 0) or not PropIntValue(Tree.Props[J].Text, Result) or (Result <= 0) then
    Result := 96;
end;

function TemplateFor(Comp: TComponent; IsRoot: Boolean; Cache: TObjectDictionary<TClass, TComponent>): TComponent;
var
  C: TClass;
begin
  C := Comp.ClassType;
  if IsRoot then
    while (C.ClassParent <> nil) and not (C.UnitName.StartsWith('Vcl.') or C.UnitName.StartsWith('System.')) do
      C := C.ClassParent;
  if not Cache.TryGetValue(C, Result) then
  begin
    if C.InheritsFrom(TCustomForm) then
      Result := TCustomFormClass(C).CreateNew(nil)
    else
      Result := TComponentClass(C).Create(nil);
    Cache.Add(C, Result);
  end;
end;

procedure ResetProp(Target, Template: TObject; const Path: string);
var
  Parts: TArray<string>;
  I: Integer;
  PI: PPropInfo;
  Cur, Tpl, Obj, TplObj: TObject;
  NoMethod: TMethod;
begin
  Parts := Path.Split(['.']);
  Cur := Target;
  Tpl := Template;
  for I := 0 to High(Parts) do
  begin
    PI := GetPropInfo(Cur, Parts[I]);
    if PI = nil then
    begin
      // Propriedade "definida" (DefineProperties), como Lines.Strings e Picture.Data:
      // o padrão é o objeto dono inteiro vazio.
      if (Cur <> Target) and (Cur is TPersistent) and (Tpl is TPersistent) then
        TPersistent(Cur).Assign(TPersistent(Tpl))
      else
        raise EPropertyError.CreateFmt('propriedade %s não encontrada', [Path]);
      Exit;
    end;
    if I < High(Parts) then
    begin
      if PI.PropType^.Kind <> tkClass then
        raise EPropertyError.CreateFmt('%s: %s não é objeto', [Path, Parts[I]]);
      Cur := GetObjectProp(Cur, PI);
      Tpl := GetObjectProp(Tpl, Parts[I]);
      if (Cur = nil) or (Tpl = nil) then
        Exit;
      Continue;
    end;
    case PI.PropType^.Kind of
      tkClass:
        begin
          Obj := GetObjectProp(Cur, PI);
          TplObj := GetObjectProp(Tpl, Parts[I]);
          if (Obj is TComponent) and not (csSubComponent in TComponent(Obj).ComponentStyle) then
            SetObjectProp(Cur, PI, nil) // referência a outro componente (PopupMenu, Images...)
          else if (Obj is TPersistent) and (TplObj is TPersistent) then
            TPersistent(Obj).Assign(TPersistent(TplObj));
        end;
      tkMethod:
        begin
          NoMethod.Code := nil;
          NoMethod.Data := nil;
          SetMethodProp(Cur, PI, NoMethod);
        end;
    else
      SetPropValue(Cur, Parts[I], GetPropValue(Tpl, Parts[I], False));
    end;
  end;
end;

procedure ReadDelta(Root: TComponent; const DeltaText: string; const Log: TDfmLogProc);
var
  Txt, Bin: TMemoryStream;
  Bytes: TBytes;
  Reader: THotReader;
begin
  Txt := TMemoryStream.Create;
  Bin := TMemoryStream.Create;
  try
    Bytes := TEncoding.ANSI.GetBytes(DeltaText);
    Txt.WriteBuffer(Bytes, Length(Bytes));
    Txt.Position := 0;
    ObjectTextToBinary(Txt, Bin);
    Bin.Position := 0;
    Reader := THotReader.Create(Bin, Log);
    try
      Reader.ApplyTo(Root);
    finally
      Reader.Free;
    end;
  finally
    Bin.Free;
    Txt.Free;
  end;
end;

function ApplyDfmText(Root: TComponent; const OldText, NewText: string; const Log: TDfmLogProc): Boolean;
var
  OldTree, NewTree: TDfmNode;
  Delta: TDfmDelta;
  Op: TDfmOp;
  Comp: TComponent;
  Later: TList<TDfmOp>;
  Templates: TObjectDictionary<TClass, TComponent>;
begin
  Result := False;
  NewTree := nil;
  Delta := nil;
  Later := nil;
  Templates := nil;
  OldTree := ParseDfm(OldText);
  try
    NewTree := ParseDfm(NewText);
    if not SameText(OldTree.TypeName, NewTree.TypeName) then
      raise EReadError.CreateFmt('o DFM agora é de %s, não de %s', [NewTree.TypeName, OldTree.TypeName]);
    // ScaleFactor é o fator acumulado de design para execução (CurrentPPI nem sempre acompanha
    // um ScaleForPPI); M/D reproduz o MulDiv que a VCL usa ao escalar.
    if Root is TControl then
      AdjustToRuntime(Root, OldTree, NewTree, Round(TControl(Root).ScaleFactor * DesignPPI(NewTree)),
        DesignPPI(NewTree));
    Delta := BuildDfmDelta(OldTree, NewTree);
    if Delta.IsEmpty then
    begin
      Log('  nada mudou');
      Exit;
    end;
    Later := TList<TDfmOp>.Create;
    Templates := TObjectDictionary<TClass, TComponent>.Create([doOwnsValues]);

    for Op in Delta.Ops do
      if Op.Kind = okWarn then
        Log('  aviso: ' + Op.Msg);

    // Mover antes de remover: se o pai antigo sair, o filho movido não vai junto.
    for Op in Delta.Ops do
      if (Op.Kind = okReparent) and not TryReparent(Root, Op) then
        Later.Add(Op);

    for Op in Delta.Ops do
      if Op.Kind = okFree then
      begin
        Comp := FindComponentByKey(Root, Op.Key);
        if Comp <> nil then
          Comp.Free;
      end;

    if Delta.Text <> '' then
      ReadDelta(Root, Delta.Text, Log);

    // O novo pai pode ter acabado de ser criado pelo delta.
    for Op in Later do
      if not TryReparent(Root, Op) then
        Log(Format('  aviso: não consegui mover %s para %s', [Op.Key, Op.ParentKey]));

    for Op in Delta.Ops do
      if Op.Kind = okResetProp then
      begin
        Comp := FindComponentByKey(Root, Op.Key);
        if Comp <> nil then
        try
          ResetProp(Comp, TemplateFor(Comp, Op.Key = '', Templates), Op.PropName);
        except
          on E: Exception do
            Log(Format('  aviso: %s.%s não voltou ao padrão: %s', [Op.Key, Op.PropName, E.Message]));
        end;
      end;

    if Root is TWinControl then
    begin
      TWinControl(Root).Realign;
      TWinControl(Root).Invalidate;
    end;
    Log('  ' + Delta.Summary);
    Result := True;
  finally
    Templates.Free;
    Later.Free;
    Delta.Free;
    NewTree.Free;
    OldTree.Free;
  end;
end;

initialization

finalization
  GClassIndex.Free;

end.
