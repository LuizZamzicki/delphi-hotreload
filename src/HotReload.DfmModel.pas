unit HotReload.DfmModel;

{
  Modelo em memória de um DFM em texto canônico e o diff entre duas versões.

  "Texto canônico" é o que sai de ObjectBinaryToText: 2 espaços por nível, propriedades no
  nível do componente + 2 e linhas de continuação (listas, coleções, binários, strings
  longas) sempre mais indentadas que a propriedade. Por isso o parser trabalha só com linha
  e indentação. Normalize com HotReload.DfmApply.DfmToCanonicalText antes de chamar ParseDfm.

  A identidade de um componente é a sua Key: o nome, prefixado pelo frame dono quando ele
  está dentro de um "inline" (ex.: 'FrameCliente1.edtNome'), que é como FindComponent acha.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TDfmKind = (dkObject, dkInherited, dkInline);

  TDfmProp = record
    Name: string;
    Text: string; // a propriedade inteira; a continuação mantém a indentação relativa
  end;

  TDfmNode = class
  private
    FChildren: TObjectList<TDfmNode>;
    FProps: TList<TDfmProp>;
    FParent: TDfmNode;
  public
    Kind: TDfmKind;
    Name: string;
    TypeName: string;
    Suffix: string; // ' [n]' quando o DFM grava a posição do filho
    constructor Create(AParent: TDfmNode);
    destructor Destroy; override;
    function IndexOfProp(const AName: string): Integer;
    function IsRoot: Boolean;
    function Key: string;
    function ParentKey: string;
    property Children: TObjectList<TDfmNode> read FChildren;
    property Props: TList<TDfmProp> read FProps;
    property Parent: TDfmNode read FParent;
  end;

  TDfmOpKind = (okFree, okResetProp, okReparent, okWarn);

  TDfmOp = record
    Kind: TDfmOpKind;
    Key: string;       // componente alvo ('' = raiz)
    PropName: string;  // okResetProp
    ParentKey: string; // okReparent: novo pai ('' = raiz)
    Msg: string;       // okWarn
  end;

  /// Resultado do diff: Text é um DFM só com o que mudou (componentes que já existem vêm
  /// como "inherited", os novos como "object"); Ops é o que o TReader não sabe fazer.
  TDfmDelta = class
  private
    FOps: TList<TDfmOp>;
  public
    Text: string;
    ChangedProps: Integer;
    NewComponents: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Add(Kind: TDfmOpKind; const Key: string; const Extra: string = '');
    function Count(Kind: TDfmOpKind): Integer;
    function IsEmpty: Boolean;
    function Summary: string;
    property Ops: TList<TDfmOp> read FOps;
  end;

function ParseDfm(const Text: string): TDfmNode;
function BuildDfmDelta(OldRoot, NewRoot: TDfmNode): TDfmDelta;
function DfmHeaderClassName(const Text: string): string;
/// O nó e a subárvore em texto DFM (indentação a partir de zero).
function DfmNodeText(N: TDfmNode): string;
/// Nó pela Key ('' devolve a raiz); nil se não houver.
function FindDfmNode(Root: TDfmNode; const Key: string): TDfmNode;

implementation

uses
  System.Generics.Defaults;

const
  CRLF = #13#10;
  KindWord: array[TDfmKind] of string = ('object', 'inherited', 'inline');

function LeadingSpaces(const S: string): Integer;
begin
  Result := 0;
  while (Result < Length(S)) and (S[Result + 1] = ' ') do
    Inc(Result);
end;

function TryParseHeader(const Line: string; out Kind: TDfmKind; out AName, AType, ASuffix: string): Boolean;
var
  S, Rest: string;
  K: TDfmKind;
  P: Integer;
begin
  Result := False;
  S := Trim(Line);
  for K := Low(TDfmKind) to High(TDfmKind) do
  begin
    if not S.StartsWith(KindWord[K] + ' ') then
      Continue;
    Rest := Trim(Copy(S, Length(KindWord[K]) + 2, MaxInt));
    ASuffix := '';
    P := Pos(' [', Rest);
    if (P > 0) and Rest.EndsWith(']') then
    begin
      ASuffix := Copy(Rest, P, MaxInt);
      Rest := Copy(Rest, 1, P - 1);
    end;
    P := Pos(': ', Rest);
    if P > 0 then
    begin
      AName := Copy(Rest, 1, P - 1);
      AType := Trim(Copy(Rest, P + 2, MaxInt));
    end
    else
    begin
      AName := '';
      AType := Rest;
    end;
    Kind := K;
    Exit(IsValidIdent(AType, True) and ((AName = '') or IsValidIdent(AName)));
  end;
end;

{ TDfmNode }

constructor TDfmNode.Create(AParent: TDfmNode);
begin
  inherited Create;
  FParent := AParent;
  FChildren := TObjectList<TDfmNode>.Create(True);
  FProps := TList<TDfmProp>.Create;
end;

destructor TDfmNode.Destroy;
begin
  FProps.Free;
  FChildren.Free;
  inherited;
end;

function TDfmNode.IndexOfProp(const AName: string): Integer;
begin
  for Result := 0 to FProps.Count - 1 do
    if SameText(FProps[Result].Name, AName) then
      Exit;
  Result := -1;
end;

function TDfmNode.IsRoot: Boolean;
begin
  Result := FParent = nil;
end;

function TDfmNode.Key: string;
var
  P: TDfmNode;
begin
  if IsRoot then
    Exit('');
  P := FParent;
  while (P <> nil) and not P.IsRoot do
  begin
    if P.Kind = dkInline then
      Exit(P.Key + '.' + Name);
    P := P.FParent;
  end;
  Result := Name;
end;

function TDfmNode.ParentKey: string;
begin
  if (FParent = nil) or FParent.IsRoot then
    Result := ''
  else
    Result := FParent.Key;
end;

{ TDfmDelta }

constructor TDfmDelta.Create;
begin
  inherited;
  FOps := TList<TDfmOp>.Create;
end;

destructor TDfmDelta.Destroy;
begin
  FOps.Free;
  inherited;
end;

procedure TDfmDelta.Add(Kind: TDfmOpKind; const Key, Extra: string);
var
  Op: TDfmOp;
begin
  Op := Default(TDfmOp);
  Op.Kind := Kind;
  Op.Key := Key;
  case Kind of
    okResetProp: Op.PropName := Extra;
    okReparent: Op.ParentKey := Extra;
    okWarn: Op.Msg := Extra;
  end;
  FOps.Add(Op);
end;

function TDfmDelta.Count(Kind: TDfmOpKind): Integer;
var
  Op: TDfmOp;
begin
  Result := 0;
  for Op in FOps do
    if Op.Kind = Kind then
      Inc(Result);
end;

function TDfmDelta.IsEmpty: Boolean;
begin
  Result := (Text = '') and (FOps.Count = 0);
end;

function TDfmDelta.Summary: string;
begin
  Result := Format('%d propriedade(s), %d componente(s) novo(s), %d removido(s)',
    [ChangedProps + Count(okResetProp), NewComponents, Count(okFree)]);
  if Count(okReparent) > 0 then
    Result := Result + Format(', %d movido(s)', [Count(okReparent)]);
end;

{ Parser }

function ParseDfm(const Text: string): TDfmNode;
var
  Lines: TStringList;
  I: Integer;

  function ParseNode(Indent: Integer; AParent: TDfmNode): TDfmNode;
  var
    L, T: string;
    Ind, P: Integer;
    Kind: TDfmKind;
    N, Ty, Suf: string;
    Prop: TDfmProp;
    SB: TStringBuilder;
  begin
    if not TryParseHeader(Lines[I], Kind, N, Ty, Suf) then
      raise EParserError.CreateFmt('DFM linha %d: esperava "object", "inherited" ou "inline": %s',
        [I + 1, Trim(Lines[I])]);
    Result := TDfmNode.Create(AParent);
    try
      Result.Kind := Kind;
      Result.Name := N;
      Result.TypeName := Ty;
      Result.Suffix := Suf;
      Inc(I);
      while I < Lines.Count do
      begin
        L := Lines[I];
        T := Trim(L);
        if T = '' then
        begin
          Inc(I);
          Continue;
        end;
        Ind := LeadingSpaces(L);
        if Ind <= Indent then
        begin
          if T <> 'end' then
            raise EParserError.CreateFmt('DFM linha %d: esperava "end": %s', [I + 1, T]);
          Inc(I);
          Exit;
        end;
        if TryParseHeader(L, Kind, N, Ty, Suf) then
        begin
          Result.FChildren.Add(ParseNode(Ind, Result));
          Continue;
        end;
        P := Pos('=', T);
        if P < 2 then
          raise EParserError.CreateFmt('DFM linha %d: esperava "Propriedade = valor": %s', [I + 1, T]);
        Prop.Name := Trim(Copy(T, 1, P - 1));
        SB := TStringBuilder.Create(T);
        try
          Inc(I);
          while (I < Lines.Count) and (LeadingSpaces(Lines[I]) > Ind) do
          begin
            SB.Append(CRLF).Append(Copy(Lines[I], Ind + 1, MaxInt));
            Inc(I);
          end;
          Prop.Text := SB.ToString;
        finally
          SB.Free;
        end;
        Result.FProps.Add(Prop);
      end;
      raise EParserError.CreateFmt('DFM: faltou o "end" de %s', [Result.Name]);
    except
      Result.Free;
      raise;
    end;
  end;

begin
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    I := 0;
    while (I < Lines.Count) and (Trim(Lines[I]) = '') do
      Inc(I);
    if I >= Lines.Count then
      raise EParserError.Create('DFM vazio');
    Result := ParseNode(LeadingSpaces(Lines[I]), nil);
  finally
    Lines.Free;
  end;
end;

function DfmHeaderClassName(const Text: string): string;
var
  Lines: TStringList;
  L, N, T, S: string;
  K: TDfmKind;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Copy(Text, 1, 1024); // só o cabeçalho; há DFM de dezenas de MB
    for L in Lines do
      if Trim(L) <> '' then
      begin
        if TryParseHeader(L, K, N, T, S) then
          Result := T;
        Exit;
      end;
  finally
    Lines.Free;
  end;
end;

{ Diff }

procedure WriteIndent(SB: TStringBuilder; Indent: Integer);
begin
  SB.Append(StringOfChar(' ', Indent));
end;

procedure WriteProp(SB: TStringBuilder; Indent: Integer; const P: TDfmProp);
var
  Line: string;
begin
  for Line in P.Text.Split([CRLF]) do
  begin
    WriteIndent(SB, Indent);
    SB.Append(Line).Append(CRLF);
  end;
end;

procedure WriteHeader(SB: TStringBuilder; Indent: Integer; Kind: TDfmKind; N: TDfmNode);
begin
  WriteIndent(SB, Indent);
  SB.Append(KindWord[Kind]).Append(' ');
  if N.Name <> '' then
    SB.Append(N.Name).Append(': ');
  SB.Append(N.TypeName).Append(N.Suffix).Append(CRLF);
end;

procedure WriteEnd(SB: TStringBuilder; Indent: Integer);
begin
  WriteIndent(SB, Indent);
  SB.Append('end').Append(CRLF);
end;

/// Escreve o nó e toda a subárvore como estão; devolve quantos componentes escreveu.
function WriteFull(SB: TStringBuilder; Indent: Integer; N: TDfmNode): Integer;
var
  P: TDfmProp;
  C: TDfmNode;
begin
  WriteHeader(SB, Indent, N.Kind, N);
  for P in N.Props do
    WriteProp(SB, Indent + 2, P);
  Result := 1;
  for C in N.Children do
    Inc(Result, WriteFull(SB, Indent + 2, C));
  WriteEnd(SB, Indent);
end;

function DfmNodeText(N: TDfmNode): string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    WriteFull(SB, 0, N);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function FindDfmNode(Root: TDfmNode; const Key: string): TDfmNode;
var
  C: TDfmNode;
begin
  if Key = '' then
    Exit(Root);
  for C in Root.Children do
  begin
    if SameText(C.Key, Key) then
      Exit(C);
    Result := FindDfmNode(C, Key);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

type
  TDeltaBuilder = class
  private
    FOld, FNew: TDfmNode;
    FOldIndex, FNewIndex: TDictionary<string, TDfmNode>;
    FDelta: TDfmDelta;
    procedure IndexTree(N: TDfmNode; Index: TDictionary<string, TDfmNode>);
    function Survives(O: TDfmNode): Boolean;
    function AncestorRemoved(O: TDfmNode): Boolean;
    procedure CollectRemoved(O: TDfmNode);
    function FindOld(N: TDfmNode; out O: TDfmNode): Boolean;
    function EmitNode(N: TDfmNode; Indent: Integer; SB: TStringBuilder): Boolean;
  public
    constructor Create(OldRoot, NewRoot: TDfmNode; Delta: TDfmDelta);
    destructor Destroy; override;
    procedure Run;
  end;

constructor TDeltaBuilder.Create(OldRoot, NewRoot: TDfmNode; Delta: TDfmDelta);
begin
  inherited Create;
  FOld := OldRoot;
  FNew := NewRoot;
  FDelta := Delta;
  FOldIndex := TDictionary<string, TDfmNode>.Create(TIStringComparer.Ordinal);
  FNewIndex := TDictionary<string, TDfmNode>.Create(TIStringComparer.Ordinal);
end;

destructor TDeltaBuilder.Destroy;
begin
  FNewIndex.Free;
  FOldIndex.Free;
  inherited;
end;

procedure TDeltaBuilder.IndexTree(N: TDfmNode; Index: TDictionary<string, TDfmNode>);
var
  C: TDfmNode;
begin
  for C in N.Children do
  begin
    if C.Name <> '' then
      Index.AddOrSetValue(C.Key, C);
    IndexTree(C, Index);
  end;
end;

function TDeltaBuilder.Survives(O: TDfmNode): Boolean;
var
  N: TDfmNode;
begin
  Result := FNewIndex.TryGetValue(O.Key, N) and SameText(N.TypeName, O.TypeName);
end;

function TDeltaBuilder.AncestorRemoved(O: TDfmNode): Boolean;
var
  P: TDfmNode;
begin
  P := O.Parent;
  while (P <> nil) and not P.IsRoot do
  begin
    if (P.Name <> '') and not Survives(P) then
      Exit(True);
    P := P.Parent;
  end;
  Result := False;
end;

procedure TDeltaBuilder.CollectRemoved(O: TDfmNode);
var
  C: TDfmNode;
begin
  for C in O.Children do
    CollectRemoved(C);
  if O.IsRoot or (O.Name = '') or Survives(O) then
    Exit;
  if O.Kind = dkInherited then
  begin
    // Vem do form ancestral (ou de dentro de um frame): não dá para liberar. Se o pai dele
    // também saiu, ele vai junto e não há o que avisar.
    if not AncestorRemoved(O) then
      FDelta.Add(okWarn, O.Key, Format('%s saiu do DFM, mas vem do form ancestral; ' +
        'o valor herdado só volta reabrindo a tela', [O.Key]));
  end
  else
    FDelta.Add(okFree, O.Key);
end;

function TDeltaBuilder.FindOld(N: TDfmNode; out O: TDfmNode): Boolean;
begin
  if FOldIndex.TryGetValue(N.Key, O) then
  begin
    if SameText(O.TypeName, N.TypeName) then
      Exit(True);
    O := nil; // trocou de classe: o antigo sai e este é criado de novo
    Exit(False);
  end;
  O := nil;
  // "inherited" sem par no DFM antigo: existe vivo, vindo do ancestral ou do frame.
  Result := N.Kind = dkInherited;
end;

function TDeltaBuilder.EmitNode(N: TDfmNode; Indent: Integer; SB: TStringBuilder): Boolean;
var
  O, C: TDfmNode;
  Body: TStringBuilder;
  P: TDfmProp;
  J: Integer;
  Kind: TDfmKind;
begin
  Result := False;
  if N.IsRoot then
    O := FOld
  else if N.Name = '' then
    Exit // sem nome não há como achar na tela viva
  else if not FindOld(N, O) then
  begin
    Inc(FDelta.NewComponents, WriteFull(SB, Indent, N));
    Exit(True);
  end;

  Body := TStringBuilder.Create;
  try
    for P in N.Props do
    begin
      if O <> nil then
        J := O.IndexOfProp(P.Name)
      else
        J := -1;
      if (J < 0) or (O.Props[J].Text <> P.Text) then
      begin
        WriteProp(Body, Indent + 2, P);
        Inc(FDelta.ChangedProps);
        Result := True;
      end;
    end;
    if O <> nil then
    begin
      for P in O.Props do
        if N.IndexOfProp(P.Name) < 0 then
          FDelta.Add(okResetProp, N.Key, P.Name);
      if not N.IsRoot and not SameText(O.ParentKey, N.ParentKey) then
        FDelta.Add(okReparent, N.Key, N.ParentKey);
    end;
    for C in N.Children do
      if EmitNode(C, Indent + 2, Body) then
        Result := True;
    if Result or N.IsRoot then
    begin
      if N.IsRoot then
        Kind := N.Kind
      else
        Kind := dkInherited;
      WriteHeader(SB, Indent, Kind, N);
      SB.Append(Body.ToString);
      WriteEnd(SB, Indent);
    end;
  finally
    Body.Free;
  end;
end;

procedure TDeltaBuilder.Run;
var
  SB: TStringBuilder;
begin
  IndexTree(FOld, FOldIndex);
  IndexTree(FNew, FNewIndex);
  CollectRemoved(FOld);
  SB := TStringBuilder.Create;
  try
    if EmitNode(FNew, 0, SB) then
      FDelta.Text := SB.ToString
    else
      FDelta.Text := '';
  finally
    SB.Free;
  end;
end;

function BuildDfmDelta(OldRoot, NewRoot: TDfmNode): TDfmDelta;
var
  B: TDeltaBuilder;
begin
  Result := TDfmDelta.Create;
  try
    B := TDeltaBuilder.Create(OldRoot, NewRoot, Result);
    try
      B.Run;
    finally
      B.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
