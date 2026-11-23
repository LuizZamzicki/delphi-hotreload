unit HrPatch;

(*
  Nível 3 do hot reload: monta um patch de código para o exe que está rodando.

  Entradas:
    - exe antigo (o que está rodando) + .map detalhado (-GD);
    - exe novo, compilado do fonte alterado em outra pasta, + .map;
    - .obj das units recompiladas (dcc32 -J), no dialeto OMF da Borland.

  Por que os três:
    - o .obj diz onde estão os pontos de correção de cada rotina (inclusive call/jmp
      relativos, que o .reloc do exe não lista), sem precisar desmontar x86;
    - os nomes no .obj são curtos e ambíguos (overloads, $bctr...), então o alvo de cada ponto
      é lido já resolvido no exe novo;
    - o endereço no exe novo é traduzido para o antigo pelos dois .map: módulo + nome +
      ordem de ocorrência + deslocamento (os dois .map vêm do mesmo fonte, a ordem bate).

  Saída: um JSON com o bloco de código novo, as correções a fazer nele (endereço no próprio
  bloco ou RVA no exe antigo) e os ganchos (RVA da rotina antiga -> deslocamento no bloco).
  Quem aplica é o exe (HotReload.Patch).

  Recusa (EPatch) quando a mudança não é só de corpo de rotina: unit nova, globais, VMT,
  typeinfo ou campos diferentes. Nesses casos o caminho é o "hrctl restart".
*)

interface

uses
  System.SysUtils, System.Classes, System.JSON;

type
  EPatch = class(Exception);

/// Units cujo .obj é mais novo que Since entram no patch. Log recebe o que mudou.
function BuildPatch(const OldExe, NewExe, ObjDir: string; Since: TDateTime; Log: TStrings): TJSONObject;

implementation

uses
  System.Generics.Collections, System.Generics.Defaults, System.IOUtils, System.NetEncoding, System.Math,
  System.Diagnostics;

{ .map }

type
  TModSeg = record
    Seg: Integer;
    Start, Len: UInt32; // VA com a base preferida
    Module, Cls: string;
    Ord: Integer;       // n-ésimo trecho desse módulo nessa classe
  end;

  TMapSym = record
    VA: UInt32;
    Name: string;
    ModIdx: Integer; // índice em ModSegs
    Occ: Integer;    // ocorrência desse nome nesse módulo (ordem de endereço)
  end;

  TMapFile = class
  private
    FSegBase: TDictionary<Integer, UInt32>;
    FSymKey: TDictionary<string, Integer>;
    FModKey: TDictionary<string, Integer>;
  public
    ModSegs: TList<TModSeg>;
    Syms: TList<TMapSym>; // ordenados por VA
    constructor Create;
    destructor Destroy; override;
    procedure Load(const FileName: string);
    function ModSegAt(VA: UInt32): Integer;
    function SymAtOrBefore(VA: UInt32; ModIdx: Integer): Integer;
    function FindSym(const Module, Name: string; Occ: Integer): Integer;
    function FindModSeg(const Module, Cls: string; Ord: Integer): Integer;
    function ModuleSize(const Module, Cls: string): UInt32;
    function HasModule(const Module: string): Boolean;
  end;

constructor TMapFile.Create;
begin
  inherited;
  FSegBase := TDictionary<Integer, UInt32>.Create;
  FSymKey := TDictionary<string, Integer>.Create(TIStringComparer.Ordinal);
  FModKey := TDictionary<string, Integer>.Create(TIStringComparer.Ordinal);
  ModSegs := TList<TModSeg>.Create;
  Syms := TList<TMapSym>.Create;
end;

destructor TMapFile.Destroy;
begin
  Syms.Free;
  ModSegs.Free;
  FModKey.Free;
  FSymKey.Free;
  FSegBase.Free;
  inherited;
end;

function ParseSegOff(const S: string; out Seg: Integer; out Off: UInt32): Boolean;
var
  P: Integer;
begin
  P := Pos(':', S);
  Result := (P = 5) and TryStrToInt('$' + Copy(S, 1, 4), Seg);
  if Result then
    Off := UInt32(StrToInt64('$' + Copy(S, 6, 8)));
end;

procedure TMapFile.Load(const FileName: string);
type
  TPart = (pHeader, pDetail, pOther, pPublics);
var
  Reader: TStreamReader;
  L, T: string;
  Part: TPart;
  Sorted: Boolean;
  Seg, I, J: Integer;
  Off: UInt32;
  Fields: TArray<string>;
  M: TModSeg;
  S: TMapSym;
  Counts: TDictionary<string, Integer>;
  Key: string;
begin
  // Linha a linha: o .map do ERP passa de 50 MB e o hrctl é 32 bits.
  Reader := TStreamReader.Create(FileName, TEncoding.ANSI, False, 1 shl 16);
  Counts := TDictionary<string, Integer>.Create(TIStringComparer.Ordinal);
  Sorted := False;
  try
    Part := pHeader;
    while not Reader.EndOfStream do
    begin
      L := Reader.ReadLine;
      T := Trim(L);
      if T.StartsWith('Detailed map of segments') then
      begin
        Part := pDetail;
        Continue;
      end;
      if T.StartsWith('Address') and T.EndsWith('Publics by Value') then
      begin
        Part := pPublics;
        if not Sorted then
        begin
          // ModSegAt usa busca binária; os símbolos guardam o índice já ordenado
          ModSegs.Sort(TComparer<TModSeg>.Construct(
            function(const A, B: TModSeg): Integer
            begin
              Result := CompareValue(A.Start, B.Start);
            end));
          Sorted := True;
        end;
        Continue;
      end;
      if T.StartsWith('Address') or T.StartsWith('Line numbers') or T.StartsWith('Bound resource') then
      begin
        Part := pOther;
        Continue;
      end;
      if (T = '') or not ParseSegOff(Copy(T, 1, 13), Seg, Off) then
        Continue;
      Fields := T.Split([' '], TStringSplitOptions.ExcludeEmpty);
      case Part of
        pHeader: // 0001:00401000 00257D10H .text CODE
          FSegBase.AddOrSetValue(Seg, Off);
        pDetail: // 0001:0024F850 0000045C C=CODE S=.text G=(none) M=uSecond ACBP=A9
          begin
            if not FSegBase.ContainsKey(Seg) then
              Continue;
            M := Default(TModSeg);
            M.Seg := Seg;
            M.Start := FSegBase[Seg] + Off;
            M.Len := UInt32(StrToInt64('$' + Fields[1]));
            for I := 2 to High(Fields) do
              if Fields[I].StartsWith('C=') then
                M.Cls := Copy(Fields[I], 3, MaxInt)
              else if Fields[I].StartsWith('M=') then
                M.Module := Copy(Fields[I], 3, MaxInt);
            Key := M.Module + '|' + M.Cls;
            if not Counts.TryGetValue(Key, J) then
              J := 0;
            M.Ord := J;
            Counts.AddOrSetValue(Key, J + 1);
            ModSegs.Add(M);
          end;
        pPublics: // 0001:00250384       uMain.TFormMain.btnSegundaClick
          begin
            if not FSegBase.ContainsKey(Seg) or (Length(Fields) < 2) then
              Continue;
            S := Default(TMapSym);
            S.VA := FSegBase[Seg] + Off;
            S.Name := Fields[1];
            S.ModIdx := ModSegAt(S.VA);
            if S.ModIdx >= 0 then
              Syms.Add(S);
          end;
      end;
    end;
    FModKey.Clear;
    for I := 0 to ModSegs.Count - 1 do
      FModKey.AddOrSetValue(ModSegs[I].Module + '|' + ModSegs[I].Cls + '|' + IntToStr(ModSegs[I].Ord), I);
    Syms.Sort(TComparer<TMapSym>.Construct(
      function(const A, B: TMapSym): Integer
      begin
        Result := CompareValue(A.VA, B.VA);
      end));
    Counts.Clear;
    for I := 0 to Syms.Count - 1 do
    begin
      S := Syms[I];
      Key := ModSegs[S.ModIdx].Module + '|' + S.Name;
      if not Counts.TryGetValue(Key, J) then
        J := 0;
      S.Occ := J;
      Counts.AddOrSetValue(Key, J + 1);
      Syms[I] := S;
      FSymKey.AddOrSetValue(Key + '|' + IntToStr(J), I);
    end;
  finally
    Counts.Free;
    Reader.Free;
  end;
end;

function TMapFile.ModSegAt(VA: UInt32): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  // ModSegs está ordenado por Start (ver Load); trechos não se sobrepõem
  Lo := 0;
  Hi := ModSegs.Count - 1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if VA < ModSegs[Mid].Start then
      Hi := Mid - 1
    else if VA >= ModSegs[Mid].Start + ModSegs[Mid].Len then
      Lo := Mid + 1
    else
      Exit(Mid);
  end;
  Result := -1;
end;

function TMapFile.SymAtOrBefore(VA: UInt32; ModIdx: Integer): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  Result := -1;
  Lo := 0;
  Hi := Syms.Count - 1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if Syms[Mid].VA <= VA then
    begin
      Result := Mid;
      Lo := Mid + 1;
    end
    else
      Hi := Mid - 1;
  end;
  // o mais próximo pode ser de outro módulo: volta até achar um do mesmo trecho
  while (Result >= 0) and (Syms[Result].ModIdx <> ModIdx) do
  begin
    if Syms[Result].VA < ModSegs[ModIdx].Start then
      Exit(-1);
    Dec(Result);
  end;
end;

function TMapFile.FindSym(const Module, Name: string; Occ: Integer): Integer;
begin
  if not FSymKey.TryGetValue(Module + '|' + Name + '|' + IntToStr(Occ), Result) then
    Result := -1;
end;

function TMapFile.FindModSeg(const Module, Cls: string; Ord: Integer): Integer;
begin
  if not FModKey.TryGetValue(Module + '|' + Cls + '|' + IntToStr(Ord), Result) then
    Result := -1;
end;

function TMapFile.ModuleSize(const Module, Cls: string): UInt32;
var
  M: TModSeg;
begin
  Result := 0;
  for M in ModSegs do
    if SameText(M.Module, Module) and SameText(M.Cls, Cls) then
      Inc(Result, M.Len);
end;

function TMapFile.HasModule(const Module: string): Boolean;
var
  M: TModSeg;
begin
  for M in ModSegs do
    if SameText(M.Module, Module) then
      Exit(True);
  Result := False;
end;

{ Imagem PE (arquivo) }

type
  TPESection = record
    Name: string;
    VA, VSize, Raw, RawSize: UInt32;
  end;

  TPEFile = class
  public
    Data: TBytes;
    ImageBase: UInt32;
    Sections: TArray<TPESection>;
    procedure Load(const FileName: string);
    function Offset(VA: UInt32): Integer; // -1 fora do arquivo
    function U32(VA: UInt32): UInt32;
    function SectionAt(VA: UInt32): Integer;
  end;

procedure TPEFile.Load(const FileName: string);
var
  Nt, Sec, I: Integer;
  NSec: Word;
  OptSize: Word;
  N: array[0..8] of AnsiChar;
begin
  Data := TFile.ReadAllBytes(FileName);
  Nt := PInteger(@Data[$3C])^;
  if PCardinal(@Data[Nt])^ <> $00004550 then
    raise EPatch.CreateFmt('%s não é um exe PE', [FileName]);
  NSec := PWord(@Data[Nt + 6])^;
  OptSize := PWord(@Data[Nt + 20])^;
  ImageBase := PCardinal(@Data[Nt + 24 + 28])^;
  Sec := Nt + 24 + OptSize;
  SetLength(Sections, NSec);
  for I := 0 to NSec - 1 do
  begin
    FillChar(N, SizeOf(N), 0);
    Move(Data[Sec + I * 40], N, 8);
    Sections[I].Name := string(PAnsiChar(@N[0]));
    Sections[I].VSize := PCardinal(@Data[Sec + I * 40 + 8])^;
    Sections[I].VA := ImageBase + PCardinal(@Data[Sec + I * 40 + 12])^;
    Sections[I].RawSize := PCardinal(@Data[Sec + I * 40 + 16])^;
    Sections[I].Raw := PCardinal(@Data[Sec + I * 40 + 20])^;
  end;
end;

function TPEFile.SectionAt(VA: UInt32): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Sections) do
    if (VA >= Sections[I].VA) and (VA < Sections[I].VA + Max(Sections[I].VSize, Sections[I].RawSize)) then
      Exit(I);
  Result := -1;
end;

function TPEFile.Offset(VA: UInt32): Integer;
var
  I: Integer;
begin
  I := SectionAt(VA);
  if (I < 0) or (VA - Sections[I].VA >= Sections[I].RawSize) then
    Exit(-1);
  Result := Integer(Sections[I].Raw + (VA - Sections[I].VA));
end;

function TPEFile.U32(VA: UInt32): UInt32;
var
  O: Integer;
begin
  O := Offset(VA);
  if (O < 0) or (O + 4 > Length(Data)) then
    raise EPatch.CreateFmt('endereço %x fora do exe', [VA]);
  Result := PCardinal(@Data[O])^;
end;

{ .obj (OMF da Borland) }

type
  TObjFixup = record
    Off: Integer;
    Rel: Boolean;
  end;

  TObjSection = class
  private
    FMask: TArray<Boolean>; // byte i é ponto de correção (montada na primeira consulta)
  public
    Name: string;
    Size: Integer;
    Data: TBytes;
    Fixups: TList<TObjFixup>;
    // preenchido na montagem
    NewVA: UInt32;
    Placed: Boolean;
    Transplant: Boolean;
    BlockOff: Integer;
    constructor Create;
    destructor Destroy; override;
    function IsFixupByte(I: Integer): Boolean;
  end;

  TObjFile = class
  public
    Module: string;
    Sections: TObjectList<TObjSection>;
    constructor Create;
    destructor Destroy; override;
    procedure Load(const FileName: string);
  end;

constructor TObjSection.Create;
begin
  inherited;
  Fixups := TList<TObjFixup>.Create;
end;

destructor TObjSection.Destroy;
begin
  Fixups.Free;
  inherited;
end;

function TObjSection.IsFixupByte(I: Integer): Boolean;
var
  F: TObjFixup;
  J: Integer;
begin
  // Há seções de dados com milhares de pontos: percorrer a lista a cada byte era quadrático.
  if Length(FMask) <> Size then
  begin
    SetLength(FMask, Size);
    for F in Fixups do
      for J := F.Off to Min(F.Off + 3, Size - 1) do
        FMask[J] := True;
  end;
  Result := (I >= 0) and (I < Size) and FMask[I];
end;

constructor TObjFile.Create;
begin
  inherited;
  Sections := TObjectList<TObjSection>.Create(True);
end;

destructor TObjFile.Destroy;
begin
  Sections.Free;
  inherited;
end;

procedure TObjFile.Load(const FileName: string);
const
  VirtBase = $4000; // índice dos segmentos virtuais (VIRDEF) no OMF da Borland
var
  D: TBytes;
  P, Len, I, Stop, SegIdx: Integer;
  Typ: Byte;
  Cur: TObjSection;
  CurOff: Integer;
  ByIndex: TDictionary<Integer, TObjSection>;
  Is32: Boolean;

  function Idx(var J: Integer): Integer;
  begin
    if D[J] and $80 <> 0 then
    begin
      Result := ((D[J] and $7F) shl 8) or D[J + 1];
      Inc(J, 2);
    end
    else
    begin
      Result := D[J];
      Inc(J);
    end;
  end;

  function VNum(var J: Integer): Integer;
  begin
    case D[J] of
      $81: begin Result := PWord(@D[J + 1])^; Inc(J, 3); end;
      $84: begin Result := D[J + 1] or (D[J + 2] shl 8) or (D[J + 3] shl 16); Inc(J, 4); end;
      $88: begin Result := PInteger(@D[J + 1])^; Inc(J, 5); end;
    else
      Result := D[J];
      Inc(J);
    end;
  end;

  function Str(var J: Integer): string;
  var
    N: Integer;
    A: AnsiString;
  begin
    N := D[J];
    SetLength(A, N);
    if N > 0 then
      Move(D[J + 1], A[1], N);
    Inc(J, N + 1);
    Result := string(A);
  end;

var
  Locat, Dro: Integer;
  FixDat, FrameMeth: Byte;
  Fix: TObjFixup;
  Off: Integer;
  S: TObjSection;
begin
  Module := ChangeFileExt(ExtractFileName(FileName), '');
  D := TFile.ReadAllBytes(FileName);
  ByIndex := TDictionary<Integer, TObjSection>.Create;
  try
    P := 0;
    Cur := nil;
    CurOff := 0;
    while P + 3 <= Length(D) do
    begin
      Typ := D[P];
      Len := PWord(@D[P + 1])^;
      I := P + 3;
      Stop := P + 3 + Len - 1; // sem o checksum
      P := P + 3 + Len;
      Is32 := Odd(Typ);
      case Typ of
        $B0: // VIRDEF: nome, tipo, segmento, tamanho
          while I < Stop do
          begin
            S := TObjSection.Create;
            S.Name := Str(I);
            Idx(I); // tipo
            Idx(I); // segmento real (_TEXT)
            S.Size := VNum(I);
            SetLength(S.Data, S.Size);
            Sections.Add(S);
            ByIndex.Add(VirtBase + Sections.Count, S);
          end;
        $A0, $A1: // LEDATA
          begin
            SegIdx := Idx(I);
            if Is32 then
            begin
              Off := PInteger(@D[I])^;
              Inc(I, 4);
            end
            else
            begin
              Off := PWord(@D[I])^;
              Inc(I, 2);
            end;
            if ByIndex.TryGetValue(SegIdx, Cur) then
            begin
              if Off + (Stop - I) > Cur.Size then
                raise EPatch.CreateFmt('%s: dados além do tamanho de %s', [FileName, Cur.Name]);
              Move(D[I], Cur.Data[Off], Stop - I);
              CurOff := Off;
            end
            else
              Cur := nil; // segmento real (tabelas de inicialização): não interessa
          end;
        $A2, $A3: // LIDATA
          begin
            SegIdx := Idx(I);
            if ByIndex.ContainsKey(SegIdx) then
              raise EPatch.CreateFmt('%s: LIDATA em segmento virtual não suportado', [FileName]);
            Cur := nil;
          end;
        $9C, $9D: // FIXUPP
          while I < Stop do
          begin
            if D[I] and $80 = 0 then
            begin
              // THREAD: só pular
              FrameMeth := (D[I] shr 2) and 7;
              Inc(I);
              if FrameMeth < 3 then
                Idx(I);
              Continue;
            end;
            Locat := (D[I] shl 8) or D[I + 1];
            Inc(I, 2);
            Dro := Locat and $3FF;
            FixDat := D[I];
            Inc(I);
            if (FixDat and $80 = 0) and (((FixDat shr 4) and 7) < 3) then
              Idx(I); // frame datum
            if FixDat and $08 = 0 then
              Idx(I); // target datum
            if FixDat and $04 = 0 then
              Inc(I, IfThen(Is32, 4, 2)); // deslocamento
            if Cur = nil then
              Continue;
            if ((Locat shr 10) and $F) <> 9 then
              raise EPatch.CreateFmt('%s: tipo de correção %d em %s não suportado',
                [FileName, (Locat shr 10) and $F, Cur.Name]);
            Fix.Off := CurOff + Dro;
            Fix.Rel := (Locat and $4000) = 0;
            Cur.Fixups.Add(Fix);
          end;
      end;
    end;
  finally
    ByIndex.Free;
  end;
end;

{ Montagem }

type
  TPatchBuilder = class
  private
    FOldMap, FNewMap: TMapFile;
    FOldPE, FNewPE: TPEFile;
    FLog: TStrings;
    FBlock: TBytesStream;
    FFixups, FHooks: TJSONArray;
    FTransplanted: TList<TObjSection>;
    FChanged, FAdded, FUnchanged: Integer;
    function Translate(NewVA: UInt32; out OldVA: UInt32; out Why: string): Boolean;
    function TargetOf(S: TObjSection; const F: TObjFixup): UInt32;
    function IsRoutine(Obj: TObjFile; S: TObjSection): Boolean;
    function FixupsPlausible(S: TObjSection; VA: UInt32): Boolean;
    procedure Place(Obj: TObjFile);
    function SameAsOld(S: TObjSection; out OldVA: UInt32): Boolean;
    procedure CheckData(Obj: TObjFile; S: TObjSection);
    procedure AddUnit(Obj: TObjFile);
    procedure Emit;
  public
    constructor Create(const OldExe, NewExe: string; Log: TStrings);
    destructor Destroy; override;
  end;

constructor TPatchBuilder.Create(const OldExe, NewExe: string; Log: TStrings);
var
  SW: TStopwatch;
begin
  inherited Create;
  FLog := Log;
  FOldMap := TMapFile.Create;
  FNewMap := TMapFile.Create;
  FOldPE := TPEFile.Create;
  FNewPE := TPEFile.Create;
  SW := TStopwatch.StartNew;
  FOldMap.Load(ChangeFileExt(OldExe, '.map'));
  FNewMap.Load(ChangeFileExt(NewExe, '.map'));
  FLog.Add(Format('  [tempo] .map: %d ms (%d símbolos)', [SW.ElapsedMilliseconds, FNewMap.Syms.Count]));
  SW := TStopwatch.StartNew;
  FOldPE.Load(OldExe);
  FNewPE.Load(NewExe);
  FLog.Add(Format('  [tempo] exes: %d ms', [SW.ElapsedMilliseconds]));
  FBlock := TBytesStream.Create;
  FFixups := TJSONArray.Create;
  FHooks := TJSONArray.Create;
  FTransplanted := TList<TObjSection>.Create;
end;

destructor TPatchBuilder.Destroy;
begin
  FTransplanted.Free;
  FHooks.Free;
  FFixups.Free;
  FBlock.Free;
  FNewPE.Free;
  FOldPE.Free;
  FNewMap.Free;
  FOldMap.Free;
  inherited;
end;

/// Endereço no exe novo -> mesmo lugar no exe antigo.
function TPatchBuilder.Translate(NewVA: UInt32; out OldVA: UInt32; out Why: string): Boolean;
var
  MI, OI, SI, OS, PS: Integer;
  M, OM: TModSeg;
  S: TMapSym;
begin
  Result := False;
  MI := FNewMap.ModSegAt(NewVA);
  if MI < 0 then
  begin
    // Fora dos módulos (.idata e afins): mesma seção, mesmo deslocamento, se o tamanho bate.
    PS := FNewPE.SectionAt(NewVA);
    if PS < 0 then
    begin
      Why := Format('endereço %x fora do exe novo', [NewVA]);
      Exit;
    end;
    for OS := 0 to High(FOldPE.Sections) do
      if (FOldPE.Sections[OS].Name = FNewPE.Sections[PS].Name) and
        (FOldPE.Sections[OS].VSize = FNewPE.Sections[PS].VSize) then
      begin
        OldVA := FOldPE.Sections[OS].VA + (NewVA - FNewPE.Sections[PS].VA);
        Exit(True);
      end;
    Why := Format('a seção %s mudou de tamanho', [FNewPE.Sections[PS].Name]);
    Exit;
  end;
  M := FNewMap.ModSegs[MI];
  OI := FOldMap.FindModSeg(M.Module, M.Cls, M.Ord);
  if OI < 0 then
  begin
    Why := Format('a unit %s (%s) não existe no exe rodando', [M.Module, M.Cls]);
    Exit;
  end;
  OM := FOldMap.ModSegs[OI];
  SI := FNewMap.SymAtOrBefore(NewVA, MI);
  if SI >= 0 then
  begin
    S := FNewMap.Syms[SI];
    OS := FOldMap.FindSym(M.Module, S.Name, S.Occ);
    if OS < 0 then
    begin
      Why := Format('%s não existe no exe rodando', [S.Name]);
      Exit;
    end;
    OldVA := FOldMap.Syms[OS].VA + (NewVA - S.VA);
  end
  else
  begin
    if M.Len <> OM.Len then
    begin
      Why := Format('a área %s de %s mudou de tamanho', [M.Cls, M.Module]);
      Exit;
    end;
    OldVA := OM.Start + (NewVA - M.Start);
  end;
  if (OldVA < OM.Start) or (OldVA > OM.Start + OM.Len) then
  begin
    Why := Format('%x cai fora de %s no exe rodando', [NewVA, M.Module]);
    Exit;
  end;
  Result := True;
end;

function TPatchBuilder.TargetOf(S: TObjSection; const F: TObjFixup): UInt32;
var
  Site, V: UInt32;
begin
  Site := S.NewVA + UInt32(F.Off);
  V := FNewPE.U32(Site);
  if F.Rel then
    Result := UInt32(Int64(Site) + 4 + Int32(V))
  else
    Result := V;
end;

function TPatchBuilder.IsRoutine(Obj: TObjFile; S: TObjSection): Boolean;
begin
  // VMT ('@TClasse@'), typeinfo e afins ('@$...'), inicialização e finalização da unit
  // são dados ou código que roda uma vez: não se transplantam.
  Result := not (S.Name.EndsWith('@') or S.Name.StartsWith('@$') or
    SameText(S.Name, '@' + Obj.Module) or SameText(S.Name, '@Finalization') or (S.Size = 0));
end;

/// Seção pequena com muitos pontos de correção (ex.: trampolim "jmp [IAT]" de função externa,
/// 6 bytes com 4 mascarados) casa em qualquer lugar só pelos bytes. Exige também que cada ponto
/// aponte para dentro do exe novo.
function TPatchBuilder.FixupsPlausible(S: TObjSection; VA: UInt32): Boolean;
var
  F: TObjFixup;
  Site, V, T: UInt32;
  O: Integer;
begin
  for F in S.Fixups do
  begin
    Site := VA + UInt32(F.Off);
    O := FNewPE.Offset(Site);
    if (O < 0) or (O + 4 > Length(FNewPE.Data)) then
      Exit(False);
    V := PCardinal(@FNewPE.Data[O])^;
    if F.Rel then
      T := UInt32(Int64(Site) + 4 + Int32(V))
    else
      T := V;
    if FNewPE.SectionAt(T) < 0 then
      Exit(False);
  end;
  Result := True;
end;

/// Acha cada seção do .obj no exe novo, na ordem, dentro dos trechos de código da unit.
procedure TPatchBuilder.Place(Obj: TObjFile);
var
  First: Integer;
  Ranges: TList<Integer>;
  Cursor: TDictionary<Integer, UInt32>;
  S: TObjSection;
  MI, I, O: Integer;
  VA, Stop: UInt32;
  Ok: Boolean;
  M: TModSeg;
begin
  Ranges := TList<Integer>.Create;
  Cursor := TDictionary<Integer, UInt32>.Create;
  try
    for MI := 0 to FNewMap.ModSegs.Count - 1 do
    begin
      M := FNewMap.ModSegs[MI];
      if SameText(M.Module, Obj.Module) and (SameText(M.Cls, 'CODE') or SameText(M.Cls, 'ICODE')) then
      begin
        Ranges.Add(MI);
        Cursor.Add(MI, M.Start);
      end;
    end;
    for S in Obj.Sections do
    begin
      // Só o que a montagem usa: rotinas (transplante) e VMT/RTTI (conferência). Bloco
      // principal do .dpr, initialization e afins custariam uma varredura inteira à toa.
      if (S.Size = 0) or not (IsRoutine(Obj, S) or S.Name.EndsWith('@') or S.Name.StartsWith('@$')) then
        Continue;
      // primeiro byte que não é ponto de correção: filtro barato antes da comparação inteira
      First := 0;
      while (First < S.Size) and S.IsFixupByte(First) do
        Inc(First);
      for MI in Ranges do
      begin
        M := FNewMap.ModSegs[MI];
        VA := Cursor[MI];
        Stop := M.Start + M.Len;
        while VA + UInt32(S.Size) <= Stop do
        begin
          O := FNewPE.Offset(VA);
          Ok := O >= 0;
          if Ok and (First < S.Size) and (FNewPE.Data[O + First] <> S.Data[First]) then
          begin
            Inc(VA);
            Continue;
          end;
          I := 0;
          while Ok and (I < S.Size) do
          begin
            if (FNewPE.Data[O + I] <> S.Data[I]) and not S.IsFixupByte(I) then
              Ok := False;
            Inc(I);
          end;
          if Ok and FixupsPlausible(S, VA) then
          begin
            S.NewVA := VA;
            S.Placed := True;
            Cursor[MI] := VA + UInt32(S.Size);
            Break;
          end;
          Inc(VA);
        end;
        if S.Placed then
          Break;
      end;
    end;
  finally
    Cursor.Free;
    Ranges.Free;
  end;
end;

/// A rotina é a mesma do exe antigo: mesmos bytes e cada correção aponta para o mesmo lugar.
function TPatchBuilder.SameAsOld(S: TObjSection; out OldVA: UInt32): Boolean;
var
  Why: string;
  NO, OO, I: Integer;
  F: TObjFixup;
  T, OT, OldSite, V: UInt32;
begin
  Result := False;
  if not Translate(S.NewVA, OldVA, Why) then
    Exit;
  NO := FNewPE.Offset(S.NewVA);
  OO := FOldPE.Offset(OldVA);
  if (NO < 0) or (OO < 0) or (OO + S.Size > Length(FOldPE.Data)) then
    Exit;
  for I := 0 to S.Size - 1 do
    if (FNewPE.Data[NO + I] <> FOldPE.Data[OO + I]) and not S.IsFixupByte(I) then
      Exit;
  for F in S.Fixups do
  begin
    if not Translate(TargetOf(S, F), T, Why) then
      Exit;
    OldSite := OldVA + UInt32(F.Off);
    V := FOldPE.U32(OldSite);
    if F.Rel then
      OT := UInt32(Int64(OldSite) + 4 + Int32(V))
    else
      OT := V;
    if OT <> T then
      Exit;
  end;
  Result := True;
end;

/// '@TFormX@' -> 'TFormX (VMT)', '@$xp$6TFormX' -> 'TFormX (RTTI)'.
function FriendlyName(const S: string): string;
var
  I: Integer;
begin
  if S.StartsWith('@$xp$') then
  begin
    I := 6;
    while (I <= Length(S)) and CharInSet(S[I], ['0'..'9']) do
      Inc(I);
    Exit(Copy(S, I, MaxInt) + ' (RTTI)');
  end;
  if S.StartsWith('@') and S.EndsWith('@') then
    Exit(Copy(S, 2, Length(S) - 2).Replace('@', '.') + ' (VMT)');
  Result := S;
end;

/// VMT, typeinfo e afins precisam estar iguais: o código novo vai usar os do exe antigo.
procedure TPatchBuilder.CheckData(Obj: TObjFile; S: TObjSection);
var
  OldVA: UInt32;
  Why: string;
begin
  if not Translate(S.NewVA, OldVA, Why) then
    raise EPatch.CreateFmt('%s, %s: %s', [Obj.Module, FriendlyName(S.Name), Why]);
  if not SameAsOld(S, OldVA) then
    raise EPatch.CreateFmt('a estrutura de %s mudou em %s (campos, métodos virtuais, published ou RTTI)', [FriendlyName(S.Name), Obj.Module]);
end;

procedure TPatchBuilder.AddUnit(Obj: TObjFile);
const
  DataClasses: array[0..2] of string = ('DATA', 'BSS', 'TLS');
var
  S: TObjSection;
  OldVA: UInt32;
  Cls: string;
begin
  if not FNewMap.HasModule(Obj.Module) then
  begin
    FLog.Add(Format('  %s: não está no exe novo (ignorada)', [Obj.Module]));
    Exit;
  end;
  if not FOldMap.HasModule(Obj.Module) then
    raise EPatch.CreateFmt('a unit %s é nova', [Obj.Module]);
  for Cls in DataClasses do
    if FNewMap.ModuleSize(Obj.Module, Cls) <> FOldMap.ModuleSize(Obj.Module, Cls) then
      raise EPatch.CreateFmt('as variáveis globais de %s mudaram (%s)', [Obj.Module, Cls]);
  Place(Obj);
  for S in Obj.Sections do
  begin
    if not S.Placed then
      Continue; // o linker descartou: ninguém usa
    if not IsRoutine(Obj, S) then
    begin
      if S.Name.EndsWith('@') or S.Name.StartsWith('@$') then
        CheckData(Obj, S);
      Continue;
    end;
    if SameAsOld(S, OldVA) then
    begin
      Inc(FUnchanged);
      Continue;
    end;
    S.Transplant := True;
    FTransplanted.Add(S);
  end;
end;

procedure TPatchBuilder.Emit;
var
  S, Other: TObjSection;
  F: TObjFixup;
  Pad: TBytes;
  O, SI, OS, NextOld: Integer;
  T, OldVA, OldEnd: UInt32;
  Why: string;
  Fix, Hook: TJSONArray;
  Sym: TMapSym;
  Found: Boolean;
  MI: Integer;
begin
  // 1. Bloco: cada rotina alinhada em 16, com os bytes do exe novo.
  for S in FTransplanted do
  begin
    SetLength(Pad, (16 - FBlock.Size mod 16) mod 16);
    if Length(Pad) > 0 then
    begin
      FillChar(Pad[0], Length(Pad), $CC);
      FBlock.WriteBuffer(Pad, Length(Pad));
    end;
    S.BlockOff := FBlock.Size;
    O := FNewPE.Offset(S.NewVA);
    FBlock.WriteBuffer(FNewPE.Data[O], S.Size);
  end;
  // 2. Correções: alvo no próprio bloco ou no exe antigo.
  for S in FTransplanted do
    for F in S.Fixups do
    begin
      T := TargetOf(S, F);
      Fix := TJSONArray.Create;
      Fix.Add(S.BlockOff + F.Off);
      Fix.Add(IfThen(F.Rel, 1, 0));
      Found := False;
      for Other in FTransplanted do
        if (T >= Other.NewVA) and (T < Other.NewVA + UInt32(Other.Size)) then
        begin
          Fix.Add(0);
          Fix.Add(Other.BlockOff + Integer(T - Other.NewVA));
          Found := True;
          Break;
        end;
      if not Found then
      begin
        if not Translate(T, OldVA, Why) then
        begin
          Fix.Free;
          raise EPatch.CreateFmt('%s: %s', [S.Name, Why]);
        end;
        Fix.Add(1);
        Fix.Add(Integer(OldVA - FOldPE.ImageBase));
      end;
      FFixups.AddElement(Fix);
    end;
  // 3. Ganchos: cada símbolo do exe novo dentro da rotina que existe no antigo.
  for S in FTransplanted do
  begin
    Found := False;
    MI := FNewMap.ModSegAt(S.NewVA);
    for SI := 0 to FNewMap.Syms.Count - 1 do
    begin
      Sym := FNewMap.Syms[SI];
      if (Sym.VA < S.NewVA) or (Sym.VA >= S.NewVA + UInt32(S.Size)) then
        Continue;
      OS := FOldMap.FindSym(FNewMap.ModSegs[MI].Module, Sym.Name, Sym.Occ);
      if OS < 0 then
        Continue;
      // espaço até o próximo símbolo no exe antigo: cabe um JMP de 5 bytes?
      NextOld := OS + 1;
      OldEnd := FOldMap.ModSegs[FOldMap.Syms[OS].ModIdx].Start + FOldMap.ModSegs[FOldMap.Syms[OS].ModIdx].Len;
      if (NextOld < FOldMap.Syms.Count) and (FOldMap.Syms[NextOld].VA < OldEnd) then
        OldEnd := FOldMap.Syms[NextOld].VA;
      Hook := TJSONArray.Create;
      Hook.Add(Integer(FOldMap.Syms[OS].VA - FOldPE.ImageBase));
      Hook.Add(S.BlockOff + Integer(Sym.VA - S.NewVA));
      Hook.Add(Integer(OldEnd - FOldMap.Syms[OS].VA));
      Hook.Add(Sym.Name);
      FHooks.AddElement(Hook);
      FLog.Add('  alterada: ' + Sym.Name);
      Found := True;
    end;
    if Found then
      Inc(FChanged)
    else
    begin
      Inc(FAdded);
      FLog.Add('  nova: ' + S.Name);
    end;
  end;
end;

function BuildPatch(const OldExe, NewExe, ObjDir: string; Since: TDateTime; Log: TStrings): TJSONObject;
var
  B: TPatchBuilder;
  SW: TStopwatch;
  Objs: TObjectList<TObjFile>;
  Obj: TObjFile;
  F: string;
  Enc: TBase64Encoding;
begin
  B := TPatchBuilder.Create(OldExe, NewExe, Log);
  Objs := TObjectList<TObjFile>.Create(True);
  Enc := TBase64Encoding.Create(0);
  try
    for F in TDirectory.GetFiles(ObjDir, '*.obj') do
      if TFile.GetLastWriteTime(F) > Since then
      begin
        Obj := TObjFile.Create;
        Objs.Add(Obj);
        SW := TStopwatch.StartNew;
        Obj.Load(F);
        Log.Add(Format('unit %s (%d seções, .obj lido em %d ms)', [Obj.Module, Obj.Sections.Count, SW.ElapsedMilliseconds]));
        SW := TStopwatch.StartNew;
        B.AddUnit(Obj);
        Log.Add(Format('  [tempo] análise: %d ms', [SW.ElapsedMilliseconds]));
      end;
    B.Emit;
    Result := TJSONObject.Create;
    Result.AddPair('block', Enc.EncodeBytesToString(Copy(B.FBlock.Bytes, 0, B.FBlock.Size)));
    Result.AddPair('fixups', B.FFixups);
    B.FFixups := nil;
    Result.AddPair('hooks', B.FHooks);
    B.FHooks := nil;
    Log.Add(Format('%d rotina(s) alterada(s), %d nova(s), %d igual(is)', [B.FChanged, B.FAdded, B.FUnchanged]));
  finally
    Enc.Free;
    Objs.Free;
    B.Free;
  end;
end;

end.
