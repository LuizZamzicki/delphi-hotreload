unit HrSetup;

(*
  "hrctl setup": prepara o hot reload de um projeto na máquina de quem roda, sem caminho fixo.

  A linha de comando do dcc32 que a IDE usaria (search path, defines, bibliotecas, saídas da
  configuração escolhida) é tirada do próprio msbuild: com /v:n ele registra a linha inteira
  antes de executar, mesmo quando ela passa de 32 mil caracteres e a execução falha (MSB6003,
  caso de projetos grandes). A partir dela são gerados, em %LOCALAPPDATA%\HotReload\<projeto>-<hash>:

    resp.txt   a linha do dcc32 sem -B (build incremental)
    make.bat   build normal no lugar do exe (usado pelo "restart")
    patch.bat  -J para os .obj das units alteradas + link do exe novo em patch\ (usado pelo "patch")

  e, ao lado do exe, o hotreload.ini ([watch]) com a pasta do fonte e os comandos acima.
*)

interface

uses
  System.SysUtils, System.Classes, System.JSON;

type
  ESetup = class(Exception);

/// ConsoleWatch: o exe abre sozinho o console do "hrctl watch" (auto=1). O plugin da IDE
/// passa False: ele mesmo faz o papel do watch.
function RunSetup(const Project, Config, Platform: string; ConsoleWatch: Boolean; Log: TStrings): TJSONObject;

implementation

uses
  Winapi.Windows, System.Win.Registry, System.IOUtils, System.IniFiles, System.Hash, System.Math;

function BdsRoot: string;
const
  Roots: array[0..1] of HKEY = (HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE);
var
  R: TRegistry;
  K: HKEY;
begin
  Result := GetEnvironmentVariable('BDS');
  if (Result <> '') and DirectoryExists(Result) then
    Exit(ExcludeTrailingPathDelimiter(Result));
  for K in Roots do
  begin
    R := TRegistry.Create(KEY_READ or KEY_WOW64_32KEY);
    try
      R.RootKey := K;
      if R.OpenKeyReadOnly('Software\Embarcadero\BDS\23.0') and R.ValueExists('RootDir') then
        Exit(ExcludeTrailingPathDelimiter(R.ReadString('RootDir')));
    finally
      R.Free;
    end;
  end;
  raise ESetup.Create('não achei o Delphi 12 (BDS 23.0) no registro');
end;

/// Roda pelo cmd.exe e devolve stdout+stderr (página OEM, como o msbuild escreve).
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
  SI.hStdInput := 0;
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
    Output := TEncoding.GetEncoding(GetOEMCP).GetString(Data.Bytes, 0, Data.Size);
  finally
    Data.Free;
    CloseHandle(Rd);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end;
end;

/// Valor de uma opção na linha do dcc32: '-E', '-NU'... (com ou sem aspas). '' se não houver.
function OptionValue(const Args, Switch: string): string;
var
  P, E: Integer;
begin
  Result := '';
  P := Pos(' ' + Switch, ' ' + Args);
  if P = 0 then
    Exit;
  Result := Copy(Args, P + Length(Switch), MaxInt);
  if (Result <> '') and (Result[1] = '"') then
  begin
    E := Pos('"', Result, 2);
    Exit(Copy(Result, 2, E - 2));
  end;
  E := Pos(' ', Result);
  if E > 0 then
    Result := Copy(Result, 1, E - 1);
end;

function RunSetup(const Project, Config, Platform: string; ConsoleWatch: Boolean; Log: TStrings): TJSONObject;
var
  Dproj, ProjDir, Bds, Work, Bat, Output, Line, Args, Dcc, MainSrc, ExeDir, Ext, Exe, NewExe,
    Resp, Make, Patch, IniName, Me: string;
  Lines: TStringList;
  Code, P: Integer;
  Ini: TIniFile;

  procedure WriteBat(const FileName, Body: string);
  begin
    TFile.WriteAllText(FileName, '@echo off'#13#10'setlocal'#13#10 + Body.Replace(#10, #13#10), TEncoding.Default);
  end;

begin
  Dproj := ExpandFileName(Project);
  if not FileExists(Dproj) then
    raise ESetup.CreateFmt('projeto não encontrado: %s', [Dproj]);
  ProjDir := ExtractFileDir(Dproj);
  Bds := BdsRoot;
  Work := TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'HotReload\' +
    ChangeFileExt(ExtractFileName(Dproj), '') + '-' +
    Copy(THashMD5.GetHashString(LowerCase(Dproj)), 1, 8));
  ForceDirectories(TPath.Combine(Work, 'patch'));

  // 1. A linha do dcc32 que a IDE usaria, registrada pelo msbuild.
  Bat := TPath.Combine(Work, 'msbuild-linha.bat');
  WriteBat(Bat, Format('call "%s\bin\rsvars.bat" >nul'#10'cd /d "%s"'#10 +
    'msbuild "%s" /t:Build /p:Config=%s /p:Platform=%s /nologo /v:n'#10,
    [Bds, ProjDir, Dproj, Config, Platform]));
  Log.Add(Format('lendo as opções de %s (%s/%s) pelo msbuild...', [ExtractFileName(Dproj), Config, Platform]));
  Code := Capture('"' + Bat + '"', ProjDir, Output);
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    Line := '';
    for P := 0 to Lines.Count - 1 do
      if (Pos('dcc32.exe ', LowerCase(Lines[P])) > 0) or (Pos('dcc64.exe ', LowerCase(Lines[P])) > 0) then
      begin
        Line := Trim(Lines[P]);
        Break;
      end;
    if Line = '' then
    begin
      for P := Max(0, Lines.Count - 15) to Lines.Count - 1 do
        Log.Add('  ' + Lines[P]);
      raise ESetup.CreateFmt('o msbuild não mostrou a linha do dcc32 (código %d); a configuração "%s" existe?',
        [Code, Config]);
    end;
  finally
    Lines.Free;
  end;
  P := Pos('.exe ', LowerCase(Line));
  Dcc := Copy(Line, 1, P + 3);
  Args := ' ' + Copy(Line, P + 5, MaxInt) + ' ';
  Args := Args.Replace(' -B ', ' ', []); // incremental
  Args := Trim(Args);

  // 2. Onde fica o exe dessa configuração.
  MainSrc := Copy(Args, Args.LastIndexOf(' ') + 2, MaxInt).Trim(['"']);
  ExeDir := OptionValue(Args, '-E');
  if ExeDir = '' then
    ExeDir := ProjDir
  else if ExtractFileDrive(ExeDir) = '' then
    ExeDir := ExpandFileName(IncludeTrailingPathDelimiter(ProjDir) + ExeDir);
  Ext := OptionValue(Args, '-TX');
  if Ext = '' then
    Ext := '.exe';
  Exe := TPath.Combine(ExeDir, ChangeFileExt(ExtractFileName(MainSrc), Ext));
  NewExe := TPath.Combine(TPath.Combine(Work, 'patch'), ExtractFileName(Exe));
  if Pos(' -GD', ' ' + Args) = 0 then
    Log.Add('aviso: a configuração não gera .map detalhado (Linking > Map file = Detailed); o patch precisa dele');

  // 3. Arquivos de build.
  Resp := TPath.Combine(Work, 'resp.txt');
  TFile.WriteAllBytes(Resp, TEncoding.Default.GetBytes(Args)); // ANSI sem BOM, como o dcc32 lê
  Make := TPath.Combine(Work, 'make.bat');
  WriteBat(Make, Format('rem Build incremental no lugar do exe (hrctl restart)'#10 +
    'call "%s\bin\rsvars.bat" >nul'#10'cd /d "%s"'#10 +
    '"%s" @"%s"'#10'set RC=%%ERRORLEVEL%%'#10'echo DCC32_EXIT=%%RC%%'#10'exit /b %%RC%%'#10,
    [Bds, ProjDir, Dcc, Resp]));
  Patch := TPath.Combine(Work, 'patch.bat');
  WriteBat(Patch, Format('rem Build do patch de código (hrctl patch), em outra pasta: o exe vivo não pode ser sobrescrito.'#10 +
    'rem 1) -J recompila só as units alteradas e grava os .obj (com -J o dcc32 não linka)'#10 +
    'rem 2) build normal na mesma pasta: só linka exe + .map'#10 +
    'call "%s\bin\rsvars.bat" >nul'#10'cd /d "%s"'#10 +
    '"%s" @"%s" -J -NO"%s\patch"'#10'set RC=%%ERRORLEVEL%%'#10'if not %%RC%%==0 goto fim'#10 +
    '"%s" @"%s" -E"%s\patch"'#10'set RC=%%ERRORLEVEL%%'#10':fim'#10'echo DCC32_EXIT=%%RC%%'#10'exit /b %%RC%%'#10,
    [Bds, ProjDir, Dcc, Resp, Work, Dcc, Resp, Work]));

  // 4. hotreload.ini ao lado do exe: pasta do fonte (THotReload.Start([])) e comandos do watch.
  ForceDirectories(ExeDir);
  IniName := TPath.Combine(ExeDir, 'hotreload.ini');
  Me := ParamStr(0);
  Ini := TIniFile.Create(IniName);
  try
    Ini.WriteString('watch', 'auto', IntToStr(Ord(ConsoleWatch)));
    Ini.WriteString('watch', 'hrctl', Me);
    Ini.WriteString('watch', 'dir', ProjDir);
    Ini.WriteString('watch', 'patch_build', Patch);
    Ini.WriteString('watch', 'new', NewExe);
    Ini.WriteString('watch', 'build', Make);
  finally
    Ini.Free;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('project', Dproj);
  Result.AddPair('config', Config);
  Result.AddPair('exe', Exe);
  Result.AddPair('work', Work);
  Result.AddPair('make', Make);
  Result.AddPair('patch', Patch);
  Result.AddPair('newExe', NewExe);
  Result.AddPair('ini', IniName);
  Result.AddPair('map', TJSONBool.Create(Pos(' -GD', ' ' + Args) > 0));
  Log.Add('exe: ' + Exe);
  Log.Add('scripts em ' + Work);
  Log.Add('hotreload.ini: ' + IniName);
end;

end.
