program hrctl;

{$APPTYPE CONSOLE}
{$I-} // saída redirecionada para "| head" fecha cedo: escrever nela não pode derrubar o programa

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON;

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
  Writeln('opcoes:');
  Writeln('  --pid N       escolhe o exe pelo PID quando ha varios');
  Writeln('  --timeout MS  tempo maximo total (padrao 15000)');
  Writeln('  --json        imprime a resposta JSON crua');
  Writeln('saida: 0 ok, 1 erro do servidor, 2 pipe nao encontrado, 3 timeout, 4 build falhou');
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
function RodarBuild(const Comando: string; Saida: TStrings): Integer;
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
    // dcc32 e cmd escrevem na página OEM do console
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

procedure Reiniciar(const Comando: string);
var
  Pipe, NovoPipe, Exe, Velho, CmdLine, Cwd, Snap, Estado: string;
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
  Snap := TPath.Combine(TPath.GetTempPath, Format('hotreload-%d.json', [Pid]));
  Info := Pedir(Pipe, 'snapshot', [Snap]);
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
  end;
  for Tentativa := 1 to 20 do
    if DeleteFile(Velho) then
      Break
    else
      Sleep(100);

  // 3. Abre o novo com o estado e espera ele restaurar as telas.
  SetEnvironmentVariable('HOTRELOAD_RESTORE', PChar(Snap));
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  UniqueString(CmdLine);
  if not CreateProcess(PChar(Exe), PChar(CmdLine), nil, nil, False, 0, nil, PChar(Cwd), SI, PI) then
    Falha('erro: nao consegui abrir o exe novo: ' + SysErrorMessage(GetLastError), 1);
  CloseHandle(PI.hThread);
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
          Break;
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

var
  I: Integer;
  A, Cmd, Build: string;
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

  Req := TJSONObject.Create;
  Arr := TJSONArray.Create;
  for I := 1 to Args.Count - 1 do
    Arr.Add(Args[I]);
  Req.AddPair('cmd', Cmd);
  Req.AddPair('args', Arr);
  Imprimir(Conversar(EscolherPipe, Req.ToJSON));
end.
