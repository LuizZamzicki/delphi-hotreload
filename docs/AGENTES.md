# Agentes de IA: `hrctl`

Um exe compilado na configuração HotReload abre um canal de controle. Com o `hrctl`, um agente
de IA (Claude Code, por exemplo) consegue ver e mexer nas telas vivas por linha de comando, sem
reabrir o programa, sem navegar até a tela e sem tirar print para conferir uma mudança. Isso
poupa tempo e tokens.

Antes de abrir o exe, defina **`HOTRELOAD_NOWATCH=1`** no ambiente. Sem isso, o exe pode abrir o
console `watch` (feito para humanos), que aplicaria patch a cada arquivo salvo e brigaria com os
comandos do agente.

## Comandos

```text
hrctl list                              exes com hot reload rodando (vários: --pid N ou --exe CAMINHO)
hrctl forms                             telas abertas (inclusive diálogo modal e telas encaixadas)
hrctl dump <form> [componente]          DFM da tela VIVA, sem blocos binários (--binary inclui)
hrctl get <form> <caminho>              get FormMain btnOk.Caption  |  get FormMain pnlTopo.Font.Size
hrctl set <form> <caminho> <valor>      dispara OnChange/OnClick como se fosse o usuário
hrctl click <form> <componente>         assíncrono: responde na hora; o efeito aparece em forms/log
hrctl shot <form> <arq.png> [comp]      print da tela ou só de um componente
hrctl reload <arquivo.dfm>              aplica o .dfm já e devolve avisos
hrctl patch --build "<cmd>" --new <exe> troca o código das rotinas alteradas sem reiniciar
hrctl restart --build "<cmd>"           recompila e reabre nas mesmas telas
hrctl open <TClasseForm> / close <form>
hrctl log [desde]                       log numerado; passe o último número para ver só o novo
hrctl setup --project X.dproj           gera os comandos de build (patch.bat, make.bat)
```

`<form>` é o `Name`, a classe ou `active`. Diálogos de `ShowMessage` e `MessageDlg` não têm
`Name`: use `TMessageForm`, com o texto em `Message.Caption` e os botões chamados `OK`, `Cancel`,
`Yes`, `No`…

Códigos de saída: 0 ok, 1 erro do comando, 2 nenhum exe, 3 timeout, 4 não compilou (nada
aplicado), 5 a mudança mexe em estrutura (use `restart`).

## Ciclo sugerido

1. Para layout: editar o `.dfm`, rodar `hrctl reload` e conferir com `get` ou `dump` em texto.
   Tirar `shot` só quando a aparência importar.
2. Para código: editar o `.pas` e rodar `hrctl patch`. Com código 5, rodar `hrctl restart`.
3. No fim, compilar pelo fluxo normal e conferir numa carga limpa da tela: depois de muitos deltas,
   a tela viva pode divergir da original.

## Skill para Claude Code (modelo)

Salve como `~/.claude/skills/hrctl/SKILL.md` e ajuste o caminho do `hrctl`:

```markdown
---
name: hrctl
description: Conversa com um exe Delphi que está rodando com hot reload para ver e mexer nas telas vivas sem reabrir o sistema e sem print, e para trocar código (patch) ou reiniciar nas mesmas telas. Use quando houver um exe com hot reload aberto (confira com "hrctl list").
---

CLI: C:\delphi-hotreload\tools\hrctl\bin\hrctl.exe

- Defina HOTRELOAD_NOWATCH=1 antes de abrir o exe.
- Confira em texto (get/dump) antes de tirar print.
- click é assíncrono: rode forms/log depois.
- .dfm: hrctl reload. Corpo de método: hrctl patch. Código 5 = estrutura mudou: hrctl restart.
- Antes de dar por terminado, compile pelo fluxo normal do projeto.
```
