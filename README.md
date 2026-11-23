# Hot reload para Delphi (VCL)

Mudar a aplicação **com ela rodando**, sem fechar o exe e sem perder o estado da tela.

## Roteiro

| Nível | O que recarrega | Situação |
|---|---|---|
| 1 | Layout (`.dfm`): salvou na IDE, a tela aberta muda | **pronto** |
| 1.5 | Canal de controle para agentes (`hrctl`): ver, conferir e mexer na tela viva | **pronto** |
| 2 | Código (`.pas`) com reinício rápido: `hrctl restart` compila, reabre o exe e volta nas mesmas telas | **pronto** |
| 3 | Código (`.pas`) sem reiniciar: compila a unit com `-J` (`.obj`), liga os símbolos aos endereços do exe vivo pelo `.map` (`-GD`) e desvia os métodos antigos com `JMP` | a fazer |

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

## Pastas

- `src\`: biblioteca (`HotReload`, `HotReload.DfmModel`, `HotReload.DfmApply`, `HotReload.Control`)
- `tools\hrctl\`: CLI para agentes (`build\build-hrctl.bat`)
- `demo\`: app de exemplo (`build\build-demo.bat` gera `demo\bin\HotDemo.exe`)
- `tests\`: testes automáticos (`build\build-tests.bat` compila e roda)
