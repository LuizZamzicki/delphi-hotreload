unit HotReload.Patch;

(*
  Nível 3 do hot reload, lado do exe: aplica um patch de código montado pelo hrctl
  (tools\hrctl\HrPatch.pas) sem reiniciar.

  O patch traz um bloco com as rotinas novas, as correções de endereço a fazer nele e os
  ganchos. Cada gancho troca o começo da rotina antiga por um JMP para a nova; quando a rotina
  antiga tem menos de 5 bytes, vai um INT3 e um tratador de exceção vetorizado desvia a
  execução. Objetos vivos, globais, VMTs e eventos continuam os mesmos: só o código muda.

  Os patches são cumulativos em relação ao exe original: cada ApplyPatch desfaz os ganchos
  anteriores antes de pôr os novos. Os blocos antigos não são liberados, porque alguma pilha
  ainda pode estar dentro deles.

  Com o depurador da IDE ligado, o INT3 para no depurador antes do tratador.
*)

interface

uses
  System.Classes;

/// Payload = JSON do hrctl. ForceInt3 força o caminho do INT3 (para testar). Devolve o resumo.
function ApplyPatch(const Payload: string; ForceInt3: Boolean; Log: TStrings): string;
/// Desfaz todos os ganchos; devolve quantos eram.
function RevertPatches: Integer;
function ActiveHooks: Integer;

implementation

uses
  Winapi.Windows, System.SysUtils, System.JSON, System.NetEncoding, System.Generics.Collections;

type
  THook = record
    Addr: PByte;
    Orig: array[0..4] of Byte;
    Count: Integer; // bytes trocados (5 = JMP, 1 = INT3)
  end;

  TInt3Map = TDictionary<Pointer, Pointer>;

  PExcPointers = ^TExcPointers;
  TExcPointers = record
    ExceptionRecord: PExceptionRecord;
    ContextRecord: PContext;
  end;

const
  EXCEPTION_CONTINUE_EXECUTION = -1;
  EXCEPTION_CONTINUE_SEARCH = 0;

function AddVectoredExceptionHandler(First: ULONG; Handler: Pointer): Pointer; stdcall;
  external kernel32 name 'AddVectoredExceptionHandler';

var
  GHooks: TList<THook>;
  GInt3: TInt3Map;     // trocado inteiro, nunca editado: o tratador lê de qualquer thread
  GVeh: Pointer;

function VectoredHandler(Info: PExcPointers): Integer; stdcall;
var
  Map: TInt3Map;
  Target: Pointer;
begin
  Result := EXCEPTION_CONTINUE_SEARCH;
  if Info.ExceptionRecord.ExceptionCode <> EXCEPTION_BREAKPOINT then
    Exit;
  Map := GInt3;
  if (Map <> nil) and Map.TryGetValue(Info.ExceptionRecord.ExceptionAddress, Target) then
  begin
    Info.ContextRecord.Eip := NativeUInt(Target);
    Result := EXCEPTION_CONTINUE_EXECUTION;
  end;
end;

procedure WriteCode(Addr: PByte; const Bytes; Count: Integer);
var
  Old: DWORD;
begin
  if not VirtualProtect(Addr, Count, PAGE_EXECUTE_READWRITE, Old) then
    RaiseLastOSError;
  Move(Bytes, Addr^, Count);
  VirtualProtect(Addr, Count, Old, Old);
  FlushInstructionCache(GetCurrentProcess, Addr, Count);
end;

function ActiveHooks: Integer;
begin
  if GHooks = nil then
    Result := 0
  else
    Result := GHooks.Count;
end;

function RevertPatches: Integer;
var
  H: THook;
  Old: TInt3Map;
begin
  Result := ActiveHooks;
  if GHooks = nil then
    Exit;
  for H in GHooks do
    WriteCode(H.Addr, H.Orig, H.Count);
  GHooks.Clear;
  Old := GInt3;
  GInt3 := nil;
  Old.Free;
end;

function ApplyPatch(const Payload: string; ForceInt3: Boolean; Log: TStrings): string;
var
  V: TJSONValue;
  P: TJSONObject;
  Block: TBytes;
  Mem, Site, Target: PByte;
  Item: TJSONValue;
  A: TJSONArray;
  Rel: Boolean;
  H: THook;
  Jmp: array[0..4] of Byte;
  Size, Jmps, Int3s: Integer;
  NewInt3: TInt3Map;
  Base: PByte;
  Enc: TBase64Encoding;
begin
  V := TJSONObject.ParseJSONValue(Payload);
  if not (V is TJSONObject) then
  begin
    V.Free;
    raise Exception.Create('patch inválido');
  end;
  P := TJSONObject(V);
  Enc := TBase64Encoding.Create(0);
  try
    Block := Enc.DecodeStringToBytes(P.GetValue<string>('block'));
    if GHooks = nil then
      GHooks := TList<THook>.Create;
    RevertPatches;
    if Length(Block) = 0 then
      Exit('nenhuma rotina diferente do exe original; ganchos anteriores desfeitos');

    Base := PByte(MainInstance);
    Mem := VirtualAlloc(nil, Length(Block), MEM_COMMIT or MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if Mem = nil then
      RaiseLastOSError;
    Move(Block[0], Mem^, Length(Block));

    // [posição no bloco, relativa?, alvo no bloco (0) ou RVA no exe (1), valor]
    for Item in P.GetValue('fixups') as TJSONArray do
    begin
      A := Item as TJSONArray;
      Site := Mem + A.Items[0].GetValue<Integer>;
      Rel := A.Items[1].GetValue<Integer> = 1;
      if A.Items[2].GetValue<Integer> = 0 then
        Target := Mem + A.Items[3].GetValue<Integer>
      else
        Target := Base + A.Items[3].GetValue<Integer>;
      if Rel then
        PInteger(Site)^ := Integer(NativeInt(Target) - NativeInt(Site) - 4)
      else
        PCardinal(Site)^ := Cardinal(Target);
    end;
    FlushInstructionCache(GetCurrentProcess, Mem, Length(Block));

    // [RVA da rotina antiga, posição no bloco, bytes livres na antiga, nome]
    Jmps := 0;
    Int3s := 0;
    NewInt3 := TInt3Map.Create;
    for Item in P.GetValue('hooks') as TJSONArray do
    begin
      A := Item as TJSONArray;
      H.Addr := Base + A.Items[0].GetValue<Integer>;
      Target := Mem + A.Items[1].GetValue<Integer>;
      Size := A.Items[2].GetValue<Integer>;
      Move(H.Addr^, H.Orig, 5);
      if (Size >= 5) and not ForceInt3 then
      begin
        Jmp[0] := $E9;
        PInteger(@Jmp[1])^ := Integer(NativeInt(Target) - NativeInt(H.Addr) - 5);
        H.Count := 5;
        WriteCode(H.Addr, Jmp, 5);
        Inc(Jmps);
      end
      else
      begin
        if GVeh = nil then
          GVeh := AddVectoredExceptionHandler(1, @VectoredHandler);
        NewInt3.Add(H.Addr, Target);
        Jmp[0] := $CC;
        H.Count := 1;
        WriteCode(H.Addr, Jmp, 1);
        Inc(Int3s);
      end;
      GHooks.Add(H);
      if Log <> nil then
        Log.Add('  ' + A.Items[3].Value);
    end;
    GInt3 := NewInt3;
    Result := Format('%d rotina(s) desviada(s) (%d JMP, %d INT3), bloco de %d bytes',
      [Jmps + Int3s, Jmps, Int3s, Length(Block)]);
  finally
    Enc.Free;
    P.Free;
  end;
end;

initialization

finalization
  // Não desfaz os ganchos: o processo está terminando e o código novo ainda pode rodar
  // em alguma finalização.
  FreeAndNil(GHooks);

end.
