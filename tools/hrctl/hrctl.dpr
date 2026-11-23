program hrctl;

{$APPTYPE CONSOLE}
{$I-} // saída redirecionada para "| head" fecha cedo: escrever nela não pode derrubar o programa

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Math,
  Winapi.ShellAPI,
  System.JSON,
  HrPatch in 'HrPatch.pas';

const
  PIPE_PREFIX = '\\.\pipe\';
  NOME_PREFIX = 'hotreload-';

var
  GPid: Integer = 0;
  GTimeout: Integer = 15000;
  GJson: Boolean = False;

procedure Uso;
begin
  Writeln('hrctl - cliente do hot reload (conversa com o exe de debug via named pipe)');
  Writeln('uso: hrctl [--pid N] [--timeout MS] [--json] <comando> [args...]');
  Writeln('comandos:');
  Writeln('  list                              lista os exes com hot reload rodando');
  Writeln('  ping');
  Writeln('  forms');
  Writeln('  dump <form> [componente] [--binary]');
  Writeln('  get <form> <caminho>');
  Writeln('  set <form> <caminho> <valor>');
  Writeln('  click <form> <componente>');
  Writeln('  shot <form> <arquivo.png>');
  Writeln('  reload <arquivo.dfm>');
  Writeln('  open <TClasseForm>');
  Writeln('  close <form>');
  Writeln('  log [desde]');
  Writeln('  snapshot <arquivo.json>');
  Writeln('  quit');
  Writeln('  restart --build "<comando>"     recompila e reabre o exe nas mesmas telas;');
  Writeln('                                  se o build falhar, o exe antigo continua rodando');
  Writeln('                                  (o comando pode vir de HOTRELOAD_BUILD)');
  Writeln('  patch --build "<comando>" --new <exe novo> [--int3]');
  Writeln('                                  troca o codigo das rotinas alteradas SEM reiniciar;');
  Writeln('                                  o build precisa gerar exe, .map e .obj (-J) em outra pasta');
  Writeln('                                  (HOTRELOAD_PATCH_BUILD / HOTRELOAD_PATCH_EXE)');
  Writeln('  unpatch                         desfaz os patches de codigo');
  Writeln('  watch --dir <fonte> --patch-build "<cmd>" --new <exe novo> --build "<cmd>" [--auto-restart]');
  Writeln('                                  modo para humanos: a cada .pas salvo roda o patch sozinho;');
  Writeln('                                  mudanca de estrutura pede R (ou reinicia com --auto-restart)');
  Writeln('opcoes:');
  Writeln('  --pid N       escolhe o exe pelo PID quando ha varios');
  Writeln('  --timeout MS  tempo maximo total (padrao 15000)');
  Writeln('  --json        imprime a resposta JSON crua');
  Writeln('saida: 0 ok, 1 erro do servidor, 2 pipe nao encontrado, 3 timeout, 4 build falhou,');
  Writeln('       5 mudanca que exige reiniciar (use restart)');
end;

function ListarPipes: TArray<string>;
var
  H: THandle;
  FD: TWin32FindData;
  L: TStringList;
  S: string;
begin
  L := TStringList.Create;
  try
    H := FindFirstFile(PChar(PIPE_PREFIX + '*'), FD);
    if H <> INVALID_HANDLE_VALUE then
    begin
      try
        repeat
          S := FD.cFileName;
          if S.StartsWith(NOME_PREFIX, True) then
            L.Add(S);
        until not FindNextFile(H, FD);
      finally
        Winapi.Windows.FindClose(H);
      end;
    end;
    Result := L.ToStringArray;
  finally
    L.Free;
  end;
end;

procedure Falha(const Msg: string; Codigo: Integer);
begin
  Writeln(ErrOutput, Msg);
  Halt(Codigo);
end;

function EscolherPipe: string;
var
  Pipes: TArray<string>;
  P: string;
  Lista: TStringList;
begin
  Result := '';
  Pipes := ListarPipes;
  if Length(Pipes) = 0 then
    Falha('nenhum exe com hot reload rodando', 2);
  if GPid > 0 then
  begin
    for P in Pipes do
      if P.StartsWith(NOME_PREFIX + IntToStr(GPid) + '-', True) then
        Exit(P);
    Falha('nenhum pipe para o pid ' + IntToStr(GPid), 2);
  end;
  if Length(Pipes) = 1 then
    Exit(Pipes[0]);
  Lista := TStringList.Create;
  try
    for P in Pipes do
      Lista.Add('  ' + P);
    Falha('varios exes rodando, use --pid N:' + sLineBreak + Lista.Text.TrimRight, 2);
  finally
    Lista.Free;
  end;
end;

// espera a operacao overlapped; em timeout cancela e sai com 3
function Esperar(H: THandle; var OV: TOverlapped; Fim: UInt64; out Bytes: DWORD;
  Pendente: Boolean): Boolean;
var
  Resta: Int64;
  W: DWORD;
begin
  Bytes := 0;
  if Pendente then
  begin
    Resta := Int64(Fim) - Int64(GetTickCount64);
    if Resta < 0 then Resta := 0;
    W := WaitForSingleObject(OV.hEvent, DWORD(Resta));
    if W = WAIT_TIMEOUT then
    begin
      CancelIo(H);
      Falha('erro: timeout aguardando resposta (' + IntToStr(GTimeout) + ' ms)', 3);
    end;
  end;
  Result := GetOverlappedResult(H, OV, Bytes, False);
end;

function Conversar(const NomePipe, Pedido: string): string;
var
  Nome: string;
  H: THandle;
  Modo: DWORD;
  OV: TOverlapped;
  Fim: UInt64;
  Dados, Total: TBytes;
  Buf: array[0..65535] of Byte;
  N: DWORD;
  Ok: Boolean;
  Err: DWORD;
  Pend: Boolean;
  Len: Integer;
begin
  Nome := PIPE_PREFIX + NomePipe;
  Fim := GetTickCount64 + UInt64(GTimeout);
  if not WaitNamedPipe(PChar(Nome), 3000) then
    Falha('erro: nao foi possivel conectar ao pipe ' + NomePipe, 2);
  H := CreateFile(PChar(Nome), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING,
    FILE_FLAG_OVERLAPPED, 0);
  if H = INVALID_HANDLE_VALUE then
    Falha('erro: nao foi possivel abrir o pipe ' + NomePipe + ' (erro ' + IntToStr(GetLastError) + ')', 2);
  try
    Modo := PIPE_READMODE_MESSAGE;
    SetNamedPipeHandleState(H, Modo, nil, nil);
    FillChar(OV, SizeOf(OV), 0);
    OV.hEvent := CreateEvent(nil, True, False, nil);
    try
      Dados := TEncoding.UTF8.GetBytes(Pedido);
      ResetEvent(OV.hEvent);
      Ok := WriteFile(H, Dados[0], Length(Dados), N, @OV);
      Pend := (not Ok) and (GetLastError = ERROR_IO_PENDING);
      if (not Ok) and (not Pend) then
        Falha('erro: falha ao enviar pedido (erro ' + IntToStr(GetLastError) + ')', 2);
      if not Esperar(H, OV, Fim, N, Pend) then
        Falha('erro: falha ao enviar pedido (erro ' + IntToStr(GetLastError) + ')', 2);

      SetLength(Total, 0);
      repeat
        ResetEvent(OV.hEvent);
        Ok := ReadFile(H, Buf, SizeOf(Buf), N, @OV);
        Err := 0;
        Pend := False;
        if not Ok then
        begin
          Err := GetLastError;
          Pend := Err = ERROR_IO_PENDING;
        end;
        if Pend then
        begin
          Ok := Esperar(H, OV, Fim, N, True);
          Err := 0;
          if not Ok then Err := GetLastError;
        end
        else if Ok then
          GetOverlappedResult(H, OV, N, False);
        if (not Ok) and (Err <> ERROR_MORE_DATA) then
          Falha('erro: falha ao ler resposta (erro ' + IntToStr(Err) + ')', 2);
        if N > 0 then
        begin
          Len := Length(Total);
          SetLength(Total, Len + Integer(N));
          Move(Buf[0], Total[Len], N);
        end;
      until Ok;
      Result := TEncoding.UTF8.GetString(Total);
    finally
      CloseHandle(OV.hEvent);
    end;
  finally
    CloseHandle(H);
  end;
end;

procedure Imprimir(const Resp: string);
var
  V: TJSONValue;
  O: TJSONObject;
  Pair: TJSONPair;
  T: TJSONValue;
  Sucesso: Boolean;
begin
  V := TJSONObject.ParseJSONValue(Resp);
  try
    if GJson then
    begin
      Writeln(Resp);
      Sucesso := (V is TJSONObject) and (TJSONObject(V).GetValue('ok') is TJSONTrue);
      if not Sucesso then Halt(1);
      Exit;
    end;
    if not (V is TJSONObject) then
      Falha('erro: resposta invalida do servidor: ' + Resp, 1);
    O := TJSONObject(V);
    if not (O.GetValue('ok') is TJSONTrue) then
    begin
      T := O.GetValue('error');
      if T <> nil then
        Writeln('erro: ' + T.Value)
      else
        Writeln('erro: ' + O.ToJSON);
      Halt(1);
    end;
    T := O.GetValue('text');
    if T <> nil then
      Writeln(T.Value);
    Pair := O.RemovePair('ok');
    Pair.Free;
    Pair := O.RemovePair('text');
    Pair.Free;
    if O.Count > 0 then
      Writeln(O.ToJSON);
  finally
    V.Free;
  end;
end;

{ restart (nível 2) }

function PipeDoPid(Pid: Cardinal): string;
var
  P: string;
begin
  for P in ListarPipes do
    if P.StartsWith(NOME_PREFIX + IntToStr(Pid) + '-', True) then
      Exit(P);
  Result := '';
end;

function Pedir(const Pipe, Cmd: string; const Args: array of string): TJSONObject;
var
  Req: TJSONObject;
  Arr: TJSONArray;
  S: string;
  V: TJSONValue;
begin
  Req := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    for S in Args do
      Arr.Add(S);
    Req.AddPair('cmd', Cmd);
    Req.AddPair('args', Arr);
    V := TJSONObject.ParseJSONValue(Conversar(Pipe, Req.ToJSON));
  finally
    Req.Free;
  end;
  if not (V is TJSONObject) then
  begin
    V.Free;
    Falha('erro: resposta invalida do servidor', 1);
  end;
  Result := TJSONObject(V);
  if not (Result.GetValue('ok') is TJSONTrue) then
    Falha('erro em ' + Cmd + ': ' + Result.GetValue<string>('error', '?'), 1);
end;

/// Roda o comando no cmd.exe e junta stdout+stderr. Devolve o código de saída.
function RodarBuild(const Comando: string; Saida: TStrings; Utf8: Boolean = False): Integer;
var
  SA: TSecurityAttributes;
  Leitura, Escrita: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Linha: string;
  Buf: array[0..4095] of Byte;
  N: DWORD;
  Dados: TBytesStream;
  Codigo: DWORD;
begin
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;
  if not CreatePipe(Leitura, Escrita, @SA, 0) then
    RaiseLastOSError;
  SetHandleInformation(Leitura, HANDLE_FLAG_INHERIT, 0);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdOutput := Escrita;
  SI.hStdError := Escrita;
  SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
  Linha := 'cmd.exe /s /c "' + Comando + '"';
  UniqueString(Linha);
  if not CreateProcess(nil, PChar(Linha), nil, nil, True, CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    CloseHandle(Leitura);
    CloseHandle(Escrita);
    RaiseLastOSError;
  end;
  CloseHandle(Escrita); // sobra só a cópia do filho: ReadFile termina quando ele sair
  Dados := TBytesStream.Create;
  try
    while ReadFile(Leitura, Buf, SizeOf(Buf), N, nil) and (N > 0) do
      Dados.WriteBuffer(Buf, N);
    WaitForSingleObject(PI.hProcess, INFINITE);
    GetExitCodeProcess(PI.hProcess, Codigo);
    Result := Integer(Codigo);
    // dcc32 e cmd escrevem na página OEM do console; o próprio hrctl escreve UTF-8
    if Utf8 then
      Saida.Text := TEncoding.UTF8.GetString(Dados.Bytes, 0, Dados.Size)
    else
      Saida.Text := TEncoding.GetEncoding(GetOEMCP).GetString(Dados.Bytes, 0, Dados.Size);
  finally
    Dados.Free;
    CloseHandle(Leitura);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end;
end;

procedure MostrarErrosDoBuild(Saida: TStrings);
var
  L: string;
  I, Mostradas: Integer;
begin
  Mostradas := 0;
  for L in Saida do
    if (Pos('Error', L) > 0) or (Pos('Fatal', L) > 0) or (Pos('error ', LowerCase(L)) > 0) then
    begin
      Writeln(L);
      Inc(Mostradas);
    end;
  if Mostradas = 0 then // sem linha reconhecível: mostra o fim da saída
    for I := Saida.Count - 20 to Saida.Count - 1 do
      if I >= 0 then
        Writeln(Saida[I]);
end;

function GetProcessId(Process: THandle): DWORD; stdcall; external kernel32 name 'GetProcessId';

const
  ERROR_ELEVATION_REQUIRED = 740;

/// Linha de comando sem o primeiro item (o exe).
function ArgsDaLinha(const Linha: string): string;
var
  I: Integer;
begin
  I := 1;
  if (Linha <> '') and (Linha[1] = '"') then
  begin
    I := Pos('"', Linha, 2);
    if I = 0 then
      Exit('');
    Inc(I);
  end
  else
    while (I <= Length(Linha)) and (Linha[I] <> ' ') do
      Inc(I);
  Result := Trim(Copy(Linha, I, MaxInt));
end;

procedure Reiniciar(const Comando: string);
var
  Pipe, NovoPipe, Exe, Velho, CmdLine, Cwd, Snap, SnapTmp, Estado: string;
  Info: TJSONObject;
  Pid: Cardinal;
  T0, T1, Limite: UInt64;
  Saida: TStringList;
  Codigo: Integer;
  HProc: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Tentativa: Integer;
  ExitCode_: DWORD;
  SEI: TShellExecuteInfo;
  Params: string;
begin
  if Comando = '' then
    Falha('erro: passe --build "<comando>" ou defina HOTRELOAD_BUILD', 1);
  Pipe := EscolherPipe;
  Info := Pedir(Pipe, 'ping', []);
  try
    Pid := Info.GetValue<Cardinal>('pid');
    Exe := Info.GetValue<string>('exe');
    CmdLine := Info.GetValue<string>('cmdline');
    Cwd := Info.GetValue<string>('cwd');
  finally
    Info.Free;
  end;

  // 1. Tira o exe vivo do caminho (o Windows deixa renomear, não apagar) e compila.
  T0 := GetTickCount64;
  Velho := Exe + '.hr-old';
  if FileExists(Velho) and not DeleteFile(Velho) then
    Falha('erro: nao consegui apagar ' + Velho + ' (outro exe usando?)', 1);
  if not RenameFile(Exe, Velho) then
    Falha('erro: nao consegui renomear o exe em uso: ' + SysErrorMessage(GetLastError), 1);
  Saida := TStringList.Create;
  try
    Codigo := RodarBuild(Comando, Saida);
    if (Codigo <> 0) or not FileExists(Exe) then
    begin
      if FileExists(Exe) then
        DeleteFile(Exe);
      RenameFile(Velho, Exe);
      Writeln(Format('build falhou (codigo %d); o exe antigo (pid %d) continua rodando com as telas como estavam', [Codigo, Pid]));
      MostrarErrosDoBuild(Saida);
      Halt(4);
    end;
  finally
    Saida.Free;
  end;
  T1 := GetTickCount64;

  // 2. Guarda o estado, fecha o exe velho.
  // Mesmo nome que o exe procura na partida (HotReload.Control.RestoreFileName)
  Snap := TPath.Combine(TPath.GetTempPath, 'hotreload-restore-' + ChangeFileExt(ExtractFileName(Exe), '') + '.json');
  // Primeiro num arquivo só deste restart: o exe velho pode apagar o nome conhecido ao fechar
  // (fim de uma restauração dele que ainda estava pendente). Move depois que ele sair.
  SnapTmp := Snap + '.' + IntToStr(Pid);
  Info := Pedir(Pipe, 'snapshot', [SnapTmp]);
  Info.Free;
  HProc := OpenProcess(SYNCHRONIZE or PROCESS_TERMINATE, False, Pid);
  Info := Pedir(Pipe, 'quit', []);
  Info.Free;
  if HProc <> 0 then
  begin
    if WaitForSingleObject(HProc, 10000) <> WAIT_OBJECT_0 then
    begin
      Writeln('aviso: o exe nao fechou em 10 s; encerrado a forca');
      TerminateProcess(HProc, 1);
      WaitForSingleObject(HProc, 5000);
    end;
    CloseHandle(HProc);
  end
  else
  begin
    // Exe elevado: sem permissão no handle; espera o pipe dele sumir.
    Limite := GetTickCount64 + 10000;
    while (PipeDoPid(Pid) <> '') and (GetTickCount64 < Limite) do
      Sleep(100);
  end;
  for Tentativa := 1 to 20 do
    if DeleteFile(Velho) then
      Break
    else
      Sleep(100);

  // 3. Abre o novo com o estado e espera ele restaurar as telas.
  if FileExists(Snap) then
    DeleteFile(Snap);
  if not RenameFile(SnapTmp, Snap) then
    Writeln('aviso: nao consegui preparar o arquivo de estado; as telas nao vao voltar');
  SetEnvironmentVariable('HOTRELOAD_RESTORE', PChar(Snap));
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  UniqueString(CmdLine);
  if CreateProcess(PChar(Exe), PChar(CmdLine), nil, nil, False, 0, nil, PChar(Cwd), SI, PI) then
    CloseHandle(PI.hThread)
  else if GetLastError = ERROR_ELEVATION_REQUIRED then
  begin
    // Manifesto pede administrador: só o ShellExecute eleva. O estado vai pelo arquivo.
    FillChar(SEI, SizeOf(SEI), 0);
    SEI.cbSize := SizeOf(SEI);
    SEI.fMask := SEE_MASK_NOCLOSEPROCESS;
    SEI.lpFile := PChar(Exe);
    Params := ArgsDaLinha(CmdLine);
    SEI.lpParameters := PChar(Params);
    SEI.lpDirectory := PChar(Cwd);
    SEI.nShow := SW_SHOWNORMAL;
    if not ShellExecuteEx(@SEI) then
      Falha('erro: nao consegui abrir o exe novo: ' + SysErrorMessage(GetLastError), 1);
    PI.hProcess := SEI.hProcess;
    PI.dwProcessId := GetProcessId(SEI.hProcess);
  end
  else
    Falha('erro: nao consegui abrir o exe novo: ' + SysErrorMessage(GetLastError), 1);
  Estado := '';
  Limite := GetTickCount64 + 30000;
  try
    while GetTickCount64 < Limite do
    begin
      if WaitForSingleObject(PI.hProcess, 0) = WAIT_OBJECT_0 then
      begin
        GetExitCodeProcess(PI.hProcess, ExitCode_);
        Falha(Format('erro: o exe novo fechou ao abrir (codigo %d)', [ExitCode_]), 1);
      end;
      NovoPipe := PipeDoPid(PI.dwProcessId);
      if NovoPipe <> '' then
      begin
        Info := Pedir(NovoPipe, 'ping', []);
        try
          Estado := Info.GetValue<string>('restore', '');
        finally
          Info.Free;
        end;
        if Estado <> 'pendente' then
          Break; // 'aguardando: ...' também serve: o exe abriu e espera o login
      end;
      Sleep(150);
    end;
  finally
    CloseHandle(PI.hProcess);
  end;
  if (Estado = '') or (Estado = 'pendente') then
    Falha(Format('erro: o exe novo (pid %d) nao respondeu em 30 s', [PI.dwProcessId]), 3);
  Writeln(Format('reiniciado: pid %d -> %d  (build %.1f s, total %.1f s)  %s',
    [Pid, PI.dwProcessId, (T1 - T0) / 1000, (GetTickCount64 - T0) / 1000, Estado]));
  Info := Pedir(NovoPipe, 'log', []);
  try
    Write(Info.GetValue<string>('text', ''));
  finally
    Info.Free;
  end;
end;

{ patch (nível 3) }

procedure AplicarPatch(const Comando: string; NovoExe: string; Int3: Boolean);
var
  Pipe, Exe, Payload: string;
  Info, P: TJSONObject;
  Saida, Log: TStringList;
  Codigo: Integer;
  T0, T1: UInt64;
begin
  if Comando = '' then
    Falha('erro: passe --build "<comando>" ou defina HOTRELOAD_PATCH_BUILD', 1);
  if NovoExe = '' then
    Falha('erro: passe --new <exe novo> ou defina HOTRELOAD_PATCH_EXE', 1);
  NovoExe := ExpandFileName(NovoExe);
  Pipe := EscolherPipe;
  Info := Pedir(Pipe, 'ping', []);
  try
    Exe := Info.GetValue<string>('exe');
  finally
    Info.Free;
  end;
  if SameText(NovoExe, Exe) then
    Falha('erro: o exe novo precisa sair em outra pasta (o que esta rodando nao pode ser sobrescrito)', 1);

  T0 := GetTickCount64;
  Saida := TStringList.Create;
  try
    Codigo := RodarBuild(Comando, Saida);
    if (Codigo <> 0) or not FileExists(NovoExe) then
    begin
      Writeln(Format('build falhou (codigo %d); nada foi aplicado, o exe continua como estava', [Codigo]));
      MostrarErrosDoBuild(Saida);
      Halt(4);
    end;
  finally
    Saida.Free;
  end;
  T1 := GetTickCount64;

  P := nil;
  Log := TStringList.Create;
  try
    try
      P := BuildPatch(Exe, NovoExe, ExtractFileDir(NovoExe), TFile.GetLastWriteTime(Exe), Log);
    except
      on E: EPatch do
      begin
        Write(Log.Text);
        Writeln('nao da para trocar sem reiniciar: ' + E.Message);
        Writeln('use: hrctl restart --build "<build normal>"');
        Halt(5);
      end;
    end;
    Write(Log.Text);
  finally
    Log.Free;
  end;
  try
    Payload := P.ToJSON;
  finally
    P.Free;
  end;
  if Int3 then
    Info := Pedir(Pipe, 'patch', [Payload, '--int3'])
  else
    Info := Pedir(Pipe, 'patch', [Payload]);
  try
    Write(Info.GetValue<string>('text', ''));
  finally
    Info.Free;
  end;
  Writeln(Format('patch aplicado (build %.1f s, total %.1f s)', [(T1 - T0) / 1000, (GetTickCount64 - T0) / 1000]));
end;

{ watch: modo para humanos }

type
  PNotify = ^TNotify;
  TNotify = record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD;
    FileName: array[0..0] of WideChar;
  end;

const
  CorNormal = FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_BLUE;
  CorOk = FOREGROUND_GREEN or FOREGROUND_INTENSITY;
  CorAviso = FOREGROUND_RED or FOREGROUND_GREEN or FOREGROUND_INTENSITY;
  CorErro = FOREGROUND_RED or FOREGROUND_INTENSITY;
  CorInfo = FOREGROUND_GREEN or FOREGROUND_BLUE or FOREGROUND_INTENSITY;
  CorFraca = FOREGROUND_INTENSITY;

procedure Cor(C: Word);
begin
  SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), C);
end;

procedure Linha(C: Word; const S: string);
begin
  Cor(C);
  Writeln(FormatDateTime('hh:nn:ss  ', Now), S);
  Cor(CorNormal);
end;

procedure Detalhe(C: Word; const S: string);
begin
  Cor(C);
  Writeln('          ', S);
  Cor(CorNormal);
end;

function RodarHrctl(const Args: string; Saida: TStrings): Integer;
begin
  Result := RodarBuild('"' + ParamStr(0) + '" ' + Args, Saida, True);
end;

const
  ENABLE_QUICK_EDIT_MODE_ = $0040;
  ENABLE_EXTENDED_FLAGS_ = $0080;

/// Mesmo nome que o exe consulta antes de abrir um watch (HotReload.WatchMutexName).
function NomeMutexWatch(const Dir: string): string;
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

procedure Vigiar(const Dir, PatchBuild, NovoExe, RestartBuild: string; AutoRestart: Boolean);
const
  Filtro = FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_LAST_WRITE;
  QuietoMs = 400;
var
  H, ConIn: THandle;
  Ov: TOverlapped;
  Buf: TBytes;
  N, Espera, W, Lidos: DWORD;
  Handles: array[0..1] of THandle;
  NH: DWORD;
  Info: PNotify;
  Nome, Up: string;
  Pendentes: TStringList;
  Ultimo: UInt64;
  Rec: TInputRecord;
  Tecla: Char;
  Armado, Sair, PrecisaReiniciar: Boolean;
  Mutex: THandle;

  procedure Armar;
  begin
    ResetEvent(Ov.hEvent);
    Armado := ReadDirectoryChangesW(H, @Buf[0], Length(Buf), True, Filtro, nil, @Ov, nil);
  end;

  function ExeRodando: Boolean;
  begin
    Result := Length(ListarPipes) > 0;
  end;

  procedure Mostrar(Saida: TStrings; C: Word; const Filtros: array of string);
  var
    L, F: string;
  begin
    for L in Saida do
      for F in Filtros do
        if (F = '*') or (Pos(F, L) > 0) then
        begin
          if Trim(L) <> '' then
            Detalhe(C, Trim(L));
          Break;
        end;
  end;

  procedure Reiniciar_;
  var
    Saida: TStringList;
  begin
    if not ExeRodando then
    begin
      Linha(CorAviso, 'o exe nao esta rodando; abra-o de novo pelo .bat');
      Exit;
    end;
    Linha(CorInfo, 'reiniciando (compila, fecha e reabre nas mesmas telas)...');
    Saida := TStringList.Create;
    try
      case RodarHrctl(Format('restart --build "%s"', [RestartBuild]), Saida) of
        0:
          begin
            Linha(CorOk, 'reiniciado');
            Mostrar(Saida, CorFraca, ['reiniciado:']);
            PrecisaReiniciar := False;
          end;
        4:
          begin
            Linha(CorErro, 'nao compilou; o exe continua aberto como estava');
            Mostrar(Saida, CorErro, ['Error', 'Fatal']);
          end;
      else
        Linha(CorErro, 'o reinicio falhou');
        Mostrar(Saida, CorErro, ['*']);
      end;
    finally
      Saida.Free;
    end;
  end;

  procedure Patch(const Motivo: string);
  var
    Saida: TStringList;
  begin
    if not ExeRodando then
    begin
      Linha(CorAviso, Motivo + ': o exe nao esta rodando');
      Exit;
    end;
    Linha(CorInfo, Motivo + ': compilando o patch...');
    Saida := TStringList.Create;
    try
      case RodarHrctl(Format('patch --build "%s" --new "%s"', [PatchBuild, NovoExe]), Saida) of
        0:
          begin
            PrecisaReiniciar := False;
            Linha(CorOk, 'codigo trocado sem reiniciar');
            Mostrar(Saida, CorFraca, ['alterada:', 'nova:', 'nenhuma rotina', 'patch aplicado']);
          end;
        4:
          begin
            Linha(CorErro, 'nao compilou; nada foi aplicado');
            Mostrar(Saida, CorErro, ['Error', 'Fatal']);
          end;
        5:
          begin
            Linha(CorAviso, 'essa mudanca mexe em estrutura e precisa reiniciar');
            Mostrar(Saida, CorAviso, ['nao da para trocar']);
            PrecisaReiniciar := True;
            if AutoRestart then
              Reiniciar_
            else
              Detalhe(CorAviso, 'aperte R para reiniciar (as telas voltam abertas)');
          end;
      else
        Linha(CorErro, 'o patch falhou');
        Mostrar(Saida, CorErro, ['*']);
      end;
    finally
      Saida.Free;
    end;
  end;

begin
  if (Dir = '') or (PatchBuild = '') or (NovoExe = '') or (RestartBuild = '') then
    Falha('erro: watch precisa de --dir, --patch-build, --new e --build', 1);
  // Um watch por pasta: o exe abre um sozinho na partida (hotreload.ini) e o restart
  // fecha e reabre o exe, então a segunda tentativa só avisa e sai.
  Mutex := CreateMutex(nil, False, PChar(NomeMutexWatch(Dir)));
  if (Mutex <> 0) and (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    Writeln('ja existe um hrctl watch vigiando ', Dir);
    CloseHandle(Mutex);
    Exit;
  end;
  SetConsoleTitle(PChar('hrctl watch - ' + Dir));
  H := CreateFile(PChar(Dir), FILE_LIST_DIRECTORY, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED, 0);
  if H = INVALID_HANDLE_VALUE then
    Falha('erro: nao consegui vigiar ' + Dir + ': ' + SysErrorMessage(GetLastError), 1);
  SetLength(Buf, 64 * 1024);
  FillChar(Ov, SizeOf(Ov), 0);
  Ov.hEvent := CreateEvent(nil, True, False, nil);
  ConIn := GetStdHandle(STD_INPUT_HANDLE);
  if not GetConsoleMode(ConIn, N) then
    ConIn := 0 // entrada redirecionada: sem teclas
  else
  begin
    // QuickEdit: um clique na janela entra em modo de seleção e congela o programa até Enter/Esc.
    SetConsoleMode(ConIn, (N or ENABLE_EXTENDED_FLAGS_) and not ENABLE_QUICK_EDIT_MODE_);
    FlushConsoleInputBuffer(ConIn);
  end;
  Pendentes := TStringList.Create;
  Pendentes.Sorted := True;
  Pendentes.Duplicates := dupIgnore;
  try
    Cor(CorInfo);
    Writeln('hrctl watch - vigiando ', Dir);
    Cor(CorNormal);
    Writeln('  .pas salvo  -> troca o codigo no exe aberto, sem fechar');
    Writeln('  .dfm salvo  -> o proprio exe aplica na tela aberta');
    Writeln('  teclas: P = patch agora   R = reiniciar   Q = sair');
    Writeln;
    if not ExeRodando then
      Linha(CorAviso, 'nenhum exe com hot reload rodando ainda');
    Armar;
    Handles[0] := Ov.hEvent;
    Handles[1] := ConIn;
    NH := IfThen(ConIn <> 0, 2, 1);
    Ultimo := 0;
    Sair := False;
    PrecisaReiniciar := False;
    while not Sair do
    begin
      if Pendentes.Count > 0 then
        Espera := 100
      else
        Espera := INFINITE;
      W := WaitForMultipleObjects(NH, @Handles[0], False, Espera);
      if W = WAIT_OBJECT_0 then
      begin
        if GetOverlappedResult(H, Ov, N, False) and (N > 0) then
        begin
          Info := @Buf[0];
          while True do
          begin
            SetString(Nome, PWideChar(@Info^.FileName[0]), Info^.FileNameLength div SizeOf(WideChar));
            Up := UpperCase(Nome);
            if (ExtractFileExt(Up) = '.PAS') and (Pos('__HISTORY', Up) = 0) and (Pos('__RECOVERY', Up) = 0) then
            begin
              Pendentes.Add(ExtractFileName(Nome));
              Ultimo := GetTickCount64;
            end;
            if Info^.NextEntryOffset = 0 then
              Break;
            Info := PNotify(PByte(Info) + Info^.NextEntryOffset);
          end;
        end;
        Armar;
      end
      else if (W = WAIT_OBJECT_0 + 1) and (ConIn <> 0) then
      begin
        while PeekConsoleInput(ConIn, Rec, 1, Lidos) and (Lidos > 0) do
        begin
          ReadConsoleInput(ConIn, Rec, 1, Lidos);
          if (Rec.EventType = KEY_EVENT) and Rec.Event.KeyEvent.bKeyDown then
          begin
            Tecla := UpCase(Rec.Event.KeyEvent.UnicodeChar);
            case Tecla of
              'Q': Sair := True;
              'R': Reiniciar_;
              'P': Patch('pedido');
            end;
          end;
        end;
      end;
      if (Pendentes.Count > 0) and (GetTickCount64 - Ultimo >= QuietoMs) then
      begin
        Nome := Pendentes.CommaText;
        Pendentes.Clear;
        // Tenta sempre: se a mudança de estrutura foi desfeita, o patch volta a servir.
        Patch(Nome + ' salvo');
      end;
    end;
  finally
    Pendentes.Free;
    if Armado then
    begin
      CancelIo(H);
      GetOverlappedResult(H, Ov, N, True);
    end;
    CloseHandle(Ov.hEvent);
    CloseHandle(H);
  end;
end;

var
  I: Integer;
  A, Cmd, Build, NovoExe, PatchBuild, Dir: string;
  Int3, AutoRestart: Boolean;
  Args: TStringList;
  Req: TJSONObject;
  Arr: TJSONArray;
  Pipes: TArray<string>;
  P: string;
begin
  SetConsoleOutputCP(CP_UTF8);
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(ErrOutput, CP_UTF8);
  Args := TStringList.Create;
  Int3 := False;
  AutoRestart := False;
  I := 1;
  while I <= ParamCount do
  begin
    A := ParamStr(I);
    if SameText(A, '--pid') and (I < ParamCount) then
    begin
      Inc(I);
      GPid := StrToIntDef(ParamStr(I), 0);
    end
    else if SameText(A, '--timeout') and (I < ParamCount) then
    begin
      Inc(I);
      GTimeout := StrToIntDef(ParamStr(I), 15000);
    end
    else if SameText(A, '--json') then
      GJson := True
    else if SameText(A, '--build') and (I < ParamCount) then
    begin
      Inc(I);
      Build := ParamStr(I);
    end
    else if SameText(A, '--new') and (I < ParamCount) then
    begin
      Inc(I);
      NovoExe := ParamStr(I);
    end
    else if SameText(A, '--int3') then
      Int3 := True
    else if SameText(A, '--auto-restart') then
      AutoRestart := True
    else if SameText(A, '--patch-build') and (I < ParamCount) then
    begin
      Inc(I);
      PatchBuild := ParamStr(I);
    end
    else if SameText(A, '--dir') and (I < ParamCount) then
    begin
      Inc(I);
      Dir := ParamStr(I);
    end
    else
      Args.Add(A);
    Inc(I);
  end;

  if (Args.Count = 0) or SameText(Args[0], 'help') then
  begin
    Uso;
    Halt(0);
  end;

  Cmd := Args[0];
  if SameText(Cmd, 'list') then
  begin
    Pipes := ListarPipes;
    if Length(Pipes) = 0 then
    begin
      Writeln('nenhum exe com hot reload rodando');
      Halt(2);
    end;
    for P in Pipes do
      Writeln(P);
    Halt(0);
  end;

  if SameText(Cmd, 'restart') then
  begin
    if Build = '' then
      Build := GetEnvironmentVariable('HOTRELOAD_BUILD');
    Reiniciar(Build);
    Halt(0);
  end;
  if SameText(Cmd, 'watch') then
  begin
    if Dir = '' then
      Dir := GetCurrentDir;
    if PatchBuild = '' then
      PatchBuild := GetEnvironmentVariable('HOTRELOAD_PATCH_BUILD');
    if NovoExe = '' then
      NovoExe := GetEnvironmentVariable('HOTRELOAD_PATCH_EXE');
    if Build = '' then
      Build := GetEnvironmentVariable('HOTRELOAD_BUILD');
    Vigiar(ExpandFileName(Dir), PatchBuild, NovoExe, Build, AutoRestart);
    Halt(0);
  end;
  if SameText(Cmd, 'patch') then
  begin
    if Build = '' then
      Build := GetEnvironmentVariable('HOTRELOAD_PATCH_BUILD');
    if NovoExe = '' then
      NovoExe := GetEnvironmentVariable('HOTRELOAD_PATCH_EXE');
    AplicarPatch(Build, NovoExe, Int3);
    Halt(0);
  end;

  Req := TJSONObject.Create;
  Arr := TJSONArray.Create;
  for I := 1 to Args.Count - 1 do
    Arr.Add(Args[I]);
  Req.AddPair('cmd', Cmd);
  Req.AddPair('args', Arr);
  Imprimir(Conversar(EscolherPipe, Req.ToJSON));
end.
