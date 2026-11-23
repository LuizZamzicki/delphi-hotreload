# Hot reload para Delphi (VCL)

Mudar a aplicação **com ela rodando**, sem fechar o exe e sem perder o estado da tela.

## Roteiro

| Nível | O que recarrega | Situação |
|---|---|---|
| 1 | Layout (`.dfm`): salvou na IDE, a tela aberta muda | **pronto** |
| 1.5 | Canal de controle para agentes (`hrctl`): ver, conferir e mexer na tela viva | **pronto** |
| 2 | Código (`.pas`) com reinício rápido: `hrctl restart` compila, reabre o exe e volta nas mesmas telas | **pronto** |
| 3 | Código (`.pas`) sem reiniciar: `hrctl patch` troca o corpo das rotinas alteradas no exe vivo | **pronto** |

## Nível 1: como usar

Adicione as três units de `src\` ao projeto e, no `.dpr`, depois de criar o form principal:

```pascal
{$IFDEF DEBUG}
THotReload.Start(['C:\Projetos Loja\MeuProjeto']);  // pastas com os .dfm
{$ENDIF}
```

Sem pastas, usa a variável de ambiente `HOTRELOAD_DIRS` (separadas por `;`). O log sai no
`OutputDebugString` (janela Event Log da IDE) e em `THotReload.OnLog`.

### Como funciona

1. Uma thread por pasta vigia os `.dfm` (`ReadDirectoryChangesW`), espera o arquivo parar de
   mudar e o normaliza (texto → binário → texto).
2. Na thread principal, compara com o DFM que a tela aberta reflete (no começo, o compilado
   no exe) e monta um delta só com o que mudou.
3. Um `TReader` próprio lê o delta **na instância viva**: componente existente vai como
   `inherited` (é procurado, não criado), componente novo vai como `object` (é criado).
4. O que o `TReader` não faz fica por conta do delta: remover componente, voltar propriedade
   apagada ao padrão e trocar o pai de um componente.
5. Tela aberta depois da mudança recebe o delta quando aparece.

### Limites atuais

- Evento novo só liga se o método já existir compilado (avisa no log).
- Componente de classe que não está linkada no exe não pode ser criado.
- Posições não são reescaladas quando a tela roda em DPI diferente do DFM.
- Em herança visual, mudar o DFM do ancestral sobrescreve o que o descendente redefiniu.

## Para agentes: `hrctl`

Com `THotReload.Start` ativo, o exe abre um named pipe (`\\.\pipe\hotreload-<pid>-<exe>`) e o CLI
`tools\hrctl\bin\hrctl.exe` conversa com ele. O objetivo é poupar tempo e tokens: o agente
não precisa reabrir o exe, navegar até a tela nem tirar print para conferir uma mudança.

```
hrctl list                              exes com hot reload rodando
hrctl forms                             telas abertas (inclusive diálogo modal) e diálogos nativos
hrctl dump <form> [componente]          DFM da tela VIVA, sem blocos binários (--binary para incluir)
hrctl get <form> <caminho>              get FormMain btnOk.Caption  |  get FormMain pnlTopo.Font.Size
hrctl set <form> <caminho> <valor>      set FormCliente edtNome.Text "Fulano"  (dispara OnChange)
hrctl click <form> <componente>         assíncrono: responde na hora, o efeito aparece em forms/log
hrctl shot <form> <arq.png> [comp]      print da tela ou só de um componente (imagem pequena)
hrctl reload <arquivo.dfm>              aplica já e devolve o resultado (avisos inclusive)
hrctl open <TClasseForm> / close <form>
hrctl log [desde]                       log numerado; passe o último número para ver só o novo
hrctl restart --build "<comando>"       recompila e reabre nas mesmas telas (nível 2)
```

### Reinício rápido (`restart`)

1. Renomeia o exe vivo (o Windows deixa renomear um exe em uso, não apagar) e roda o build.
2. **Build falhou:** desfaz a troca, mostra só as linhas de erro e sai com 4. O exe antigo
   continua aberto com as telas como estavam.
3. **Build passou:** pede `snapshot` (telas abertas, posição, campos, checkboxes, abas e foco;
   controles ligados a banco ficam de fora) e `quit`. Depois abre o exe novo com
   `HOTRELOAD_RESTORE=<snapshot>` e espera o `ping` dizer que a restauração terminou.

No demo, com `build\make-demo.bat` (incremental), o ciclo inteiro leva cerca de 0,5 s. O comando de
build precisa devolver o código do dcc32 (`exit /b`); pode ficar em `HOTRELOAD_BUILD`.

`<form>` é o `Name`, a classe (diálogos do `ShowMessage`/`MessageDlg` não têm `Name`: use
`TMessageForm`) ou `active`. Códigos de saída: 0 ok, 1 erro do comando, 2 sem exe, 3 timeout.

Ciclo típico de um ajuste de layout: editar o `.dfm` → `hrctl reload uX.dfm` → `hrctl get`/`dump`
para conferir em texto → `shot` só se a parte visual importar. Hot reload serve para iterar; no fim,
compilar de verdade e conferir numa carga limpa da tela.

## Nível 3: trocar código sem reiniciar (`patch`)

```
hrctl patch --build "build\patch-demo.bat" --new demo\bin\patch\HotDemo.exe
```

O exe continua no ar, com as mesmas telas, objetos e variáveis globais: só o código das rotinas
alteradas muda. No demo, o ciclo leva cerca de 1 s.

**Build** (`build\patch-demo.bat`): em outra pasta, porque o exe vivo não pode ser sobrescrito.
1. `dcc32 -J` recompila só as units alteradas e grava `.dcu` e `.obj` (com `-J` ele não linka).
2. `dcc32` normal na mesma pasta só linka o exe e o `.map` (`-GD`).

**Análise** (`tools\hrctl\HrPatch.pas`), para cada `.obj` mais novo que o exe vivo:
- O `.obj` (OMF da Borland, um "segmento virtual" por rotina, VMT ou typeinfo) diz onde estão os
  pontos de correção de cada rotina, inclusive os `call`/`jmp` relativos, sem desmontar x86.
- Cada rotina é localizada no exe novo e o alvo de cada ponto é lido lá, já resolvido. Os nomes do
  `.obj` são curtos e ambíguos, então não servem para isso.
- O alvo é traduzido para o exe vivo pelos dois `.map`: unit + nome + ordem de ocorrência +
  deslocamento. Os dois saem do mesmo fonte, então overloads se casam pela ordem.
- Rotina idêntica à antiga (mesmos bytes e mesmos alvos) fica de fora; só as alteradas vão.
- VMT, RTTI e globais da unit precisam estar iguais ao exe vivo. Se não estiverem, o comando
  recusa com código 5 e manda usar `restart`.

**Aplicação** (`src\HotReload.Patch.pas`, dentro do exe):
1. Aloca memória executável, copia as rotinas novas e corrige os endereços.
2. Troca os 5 primeiros bytes de cada rotina antiga por um `JMP` para a nova. Rotina antiga com
   menos de 5 bytes recebe um `INT3`, e um tratador de exceção vetorizado desvia a execução
   (`--int3` força esse caminho, para teste).
3. O patch é cumulativo em relação ao exe original: cada `patch` desfaz os ganchos anteriores
   antes de aplicar os novos, então voltar o fonte e rodar `patch` de novo restaura o código
   original. `hrctl unpatch` desfaz tudo.

**Limites:**
- Só serve para mudança no corpo de rotinas.
- Exigem `restart`: campo novo, método virtual novo, mudança no que é `published`, variável global
  nova e unit nova.
- O código de `initialization` não roda de novo.
- Com o depurador da IDE ligado, o `INT3` para no depurador.

## Plugin da IDE (o jeito mais fácil)

Um pacote de design-time para o Delphi 12 (`tools\ide`). Faz na própria IDE o papel do `watch`:
o patch roda quando você salva, e o resultado aparece na janela **Messages** (grupo "Hot
Reload"). Erro de compilação leva à linha com duplo clique.

Menu **Hot Reload**:
- **Ativar neste projeto:** cria a build configuration HotReload (filha da Release, com o define
  `HOTRELOAD` e `.map` detalhado). Acrescenta ao `.dpr`, dentro de `{$IFDEF HOTRELOAD}`, as units
  de `src\` (caminho relativo) e o `THotReload.Start([])`. Depois roda o `hrctl setup`.
- **Patch agora** e **Reiniciar**.
- **Patch automático ao salvar:** ligado por padrão. Só dispara com a configuração HotReload
  ativa e quando o `.pas` mudou de fato; o `.dfm` o próprio exe aplica.

O plugin chama o `hrctl` (procurado em `tools\hrctl\bin`, a partir do `.bpl`). Os comandos de
build vêm do `hrctl setup`, que lê as opções da IDE pelo `msbuild`, então não há caminho fixo da
máquina de ninguém.

### Para mandar para outra pessoa

1. Clonar este repositório (de preferência em `C:\Projetos Loja\hotreload`, ao lado dos
   projetos).
2. Rodar `build\build-hrctl.bat` e `build\build-ide.bat` (Delphi 12 no caminho padrão).
3. Na IDE: **Component > Install Packages > Add...** e escolher
   `tools\ide\bin\HotReloadIDE.bpl`.
4. Abrir o projeto, **Hot Reload > Ativar neste projeto**, escolher a configuração HotReload e
   rodar (F9). A partir daí, é salvar e ver a mudança.

Se o programa precisa de arquivos ao lado do exe (`config.ini`, DLLs, banco), aponte o "Output
directory" da configuração HotReload para uma pasta que os tenha.

### `hrctl setup`

```
hrctl setup --project X.dproj [--config HotReload] [--platform Win32] [--no-console]
```

1. Roda o `msbuild` só para capturar a linha do `dcc32`. O `msbuild` registra a linha inteira
   mesmo quando ela passa de 32 mil caracteres e a execução falha, que é o caso do ERP.
2. Gera, em `%LOCALAPPDATA%\HotReload\<projeto>-<hash>`:
   - `resp.txt`: a linha sem `-B`;
   - `make.bat`: o build do restart;
   - `patch.bat`: `-J` mais o link em `patch\`.
3. Grava o `hotreload.ini` ao lado do exe, com a pasta do fonte e esses comandos.

Funciona sem o plugin também: sem `--no-console`, o exe abre o console do `watch` sozinho.

## Para humanos: `hrctl watch`

O exe abre sozinho o console do `watch` quando inicia, desde que exista um `hotreload.ini` ao
lado dele com `auto=1`. O do demo é `demo\hotreload.ini`, copiado para `demo\bin` pelo build; o
do ERP é gerado pelo `setup_hr.py`. Assim funciona do mesmo jeito abrindo pela IDE, por duplo
clique ou depois de um `restart`.

- Há um `watch` por pasta (mutex): se já houver um aberto, o exe não abre outro.
- `HOTRELOAD_NOWATCH=1` no ambiente desliga a abertura automática. Agentes devem usar isso:
  senão, o `watch` aplicaria patch sozinho enquanto o agente edita.
- Sem o `.ini`, `build\dev-demo.bat` faz o mesmo à mão.

O console vigia o fonte:

- `.dfm` salvo: o próprio exe aplica na tela aberta (nível 1).
- `.pas` salvo: roda o `patch` sozinho e mostra uma linha colorida:
  - verde: código trocado sem reiniciar;
  - vermelho: não compilou, e nada foi aplicado;
  - amarelo: a mudança mexe em estrutura, aperte **R** para reiniciar (as telas voltam abertas).
- Teclas: **P** = patch agora, **R** = reiniciar, **Q** = sair. Com `--auto-restart`, a mudança
  estrutural reinicia sem perguntar.

Agentes não usam o `watch`: chamam `patch`, `restart` e os outros comandos direto, e leem o código
de saída.

## Exe que pede elevação (manifesto `requireAdministrator`)

O ERP roda como administrador. Para o `hrctl`, que roda sem elevação, funcionar com ele:

- o pipe é criado liberando o próprio usuário (sem isso, "acesso negado");
- o `restart` abre o exe novo pelo `ShellExecuteEx` quando o `CreateProcess` responde "elevação
  necessária";
- o estado vai por um arquivo no `%TEMP%`, porque o processo elevado não herda o ambiente.

## Restauração depois de um login

O `restart` só reabre as telas quando o programa está pronto:

- as telas que eram modais no snapshot voltaram (o form principal do ERP roda com `ShowModal` e
  só aparece depois do login);
- não há outra tela modal aberta (um login, um aviso).

Telas encaixadas em abas (`ManualDock`, como o ERP faz no `pg_principal`) voltam encaixadas, pelo
mesmo caminho do `DockForm` do ERP: `ManualDock`, maximizar e `Show`. Depois o `Tag` da aba é
corrigido para o endereço novo do form, e a ordem das abas e a aba ativa são recolocadas. O
`hrctl forms` mostra `encaixada em Form.Controle`.

Antes disso, o `ping` mostra `aguardando: ...`. Telas escondidas e modais não são recriadas, porque
quem abre essas é o próprio programa. Os campos restaurados são os de qualquer controle de edição
(`Text`, inclusive DevExpress), mais checkboxes, abas e posição. Controles ligados a banco ficam de
fora.

## Pastas

- `src\`: biblioteca (`HotReload`, `HotReload.DfmModel`, `HotReload.DfmApply`, `HotReload.Control`, `HotReload.Patch`)
- `tools\hrctl\`: CLI para agentes (`build\build-hrctl.bat`)
- `tools\ide\`: plugin da IDE (`build\build-ide.bat` gera `tools\ide\bin\HotReloadIDE.bpl`)
- `demo\`: app de exemplo (`build\build-demo.bat` gera `demo\bin\HotDemo.exe`)
- `tests\`: testes automáticos (`build\build-tests.bat` compila e roda)
