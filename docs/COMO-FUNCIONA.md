# Como funciona

Três peças:

- **Dentro do exe** (`src\`): units que entram no programa só na configuração HotReload. Elas
  aplicam `.dfm`, recebem o código novo e guardam e restauram o estado das telas.
- **`hrctl`** (`tools\hrctl`): CLI que conversa com o exe por um named pipe, monta os patches de
  código e faz o reinício. É usado pelo plugin, pelo console `watch` e por agentes de IA.
- **Plugin da IDE** (`tools\ide`): menu, aviso de arquivo salvo e janela Messages; chama o `hrctl`.

## `.dfm` na tela aberta

1. Uma thread por pasta vigia os `.dfm` (`ReadDirectoryChangesW`), espera o arquivo parar de
   mudar e o normaliza (texto → binário → texto).
2. Na thread principal, compara com o DFM que a tela aberta reflete (no começo, o compilado no
   exe) e monta um delta só com o que mudou.
3. Um `TReader` próprio lê o delta **na instância viva**: componente existente vai como
   `inherited` (é procurado, não criado), componente novo vai como `object` (é criado). Não se usa
   `ReadRootComponent`, que renomearia a tela (`Form1` viraria `Form1_1`).
4. O que o `TReader` não faz fica por conta do delta: remover componente (o campo publicado vira
   `nil` sozinho), voltar propriedade apagada ao padrão (copiado de uma instância nova da classe)
   e trocar o pai de um componente.
5. Posições e tamanhos que mudaram são convertidos para o valor em execução:
   `novo × escala + (valor vivo − antigo × escala)`. A escala vem de `TControl.ScaleFactor` (a VCL
   escala a tela para o DPI do monitor ao carregar). O termo entre parênteses é o deslocamento
   que o controle já tinha em relação ao DFM, por âncoras ou alinhamento.
6. Tela aberta depois da mudança recebe o delta quando aparece.

Componente cuja classe não é campo do form é achado varrendo as VMTs do exe (cada VMT aponta para
si mesma em `vmtSelfPtr`): num exe sem runtime packages, a RTTI estendida não lista todas as
classes linkadas.

## Canal de controle

O exe abre `\\.\pipe\hotreload-<pid>-<exe>`, em modo mensagem: um pedido JSON
`{"cmd": "...", "args": [...]}` e uma resposta JSON por conexão. Os comandos rodam na thread
principal (`Synchronize`); os que podem abrir diálogo modal (`click`, `close`) só são
enfileirados. Exe que pede elevação (`requireAdministrator`) cria o pipe liberando o próprio
usuário, senão o `hrctl` sem elevação levaria "acesso negado".

## Reinício com as telas de volta (`restart`)

1. Renomeia o exe vivo (o Windows deixa renomear um exe em uso, não apagar) e roda o build.
2. **Build falhou:** desfaz a troca e mostra só as linhas de erro. O exe antigo continua aberto,
   com as telas como estavam.
3. **Build passou:** pede um `snapshot` (telas abertas, posição, campos, checkboxes, abas, foco
   e onde cada tela estava encaixada) e fecha o exe. O snapshot vai para um arquivo no `%TEMP%`,
   porque um processo elevado não herda o ambiente. Depois abre o exe novo.

O exe novo só restaura quando está pronto:
- as telas que eram modais no snapshot voltaram (há sistemas cujo form principal roda com
  `ShowModal` e só aparece depois do login);
- não há outra tela modal aberta (um login, um aviso);
- passaram 1,5 s nesse estado.

Telas escondidas e modais não são recriadas, porque quem as abre é o próprio programa.

Telas encaixadas em abas (`ManualDock`) voltam pelo mesmo caminho de um `DockForm` típico:
`ManualDock`, maximizar e `Show`. Depois o `Tag` da aba é corrigido para o endereço novo do form,
e a ordem das abas e a aba ativa são recolocadas.

## Trocar código sem reiniciar (`patch`)

**Build**, em outra pasta, porque o exe vivo não pode ser sobrescrito:
1. `dcc32 -J` recompila só as units alteradas e grava `.dcu` e `.obj`; com `-J`, o `dcc32` não
   linka.
2. `dcc32` normal na mesma pasta: os `.dcu` já estão em dia, então só linka o exe e o `.map`
   detalhado.

**Análise** (`tools\hrctl\HrPatch.pas`), para cada `.obj` mais novo que o exe vivo:
- O `.obj` usa o OMF da Borland, com um "segmento virtual" (registro `0xB0`) por rotina, VMT ou
  typeinfo. Ele diz onde estão os pontos de correção de cada rotina, inclusive os `call` e `jmp`
  relativos, sem precisar desmontar x86.
- Cada rotina é localizada no exe novo, e o alvo de cada ponto é lido lá, já resolvido. Os nomes
  do `.obj` são curtos e ambíguos (sem unit e sem parâmetros), então não servem para isso.
- O alvo é traduzido para o exe vivo pelos dois `.map`: unit + nome + ordem de ocorrência +
  deslocamento. Os dois saem do mesmo fonte, então overloads se casam pela ordem.
- Rotina idêntica à antiga (mesmos bytes e mesmos alvos) fica de fora.
- VMT, RTTI e globais da unit precisam estar iguais ao exe vivo. Se não estiverem, o patch é
  recusado e o caminho é o reinício.

**Aplicação** (`src\HotReload.Patch.pas`, dentro do exe):
1. Aloca memória executável, copia as rotinas novas e corrige os endereços.
2. Troca os 5 primeiros bytes de cada rotina antiga por um `JMP` para a nova. Rotina com menos de
   5 bytes recebe um `INT3`, e um tratador de exceção vetorizado desvia a execução.
3. O patch é cumulativo em relação ao exe original: cada `patch` desfaz os ganchos anteriores
   antes de aplicar os novos. Voltar o fonte e rodar `patch` de novo restaura o código original.

Num projeto de 2 milhões de linhas (exe de 117 MB, `.map` de 58 MB), a análise leva cerca de
2,5 s. O resto do tempo é o build e o link.

## Opções de build sem caminho fixo (`hrctl setup`)

O `msbuild` do Delphi registra a linha inteira do `dcc32` (com `/v:n`) antes de executá-la, mesmo
quando ela passa de 32 mil caracteres e a execução falha (MSB6003). O `hrctl setup` captura essa
linha para a configuração escolhida e gera, em `%LOCALAPPDATA%\HotReload\<projeto>-<hash>`:

- `resp.txt`: a linha sem `-B` (build incremental);
- `make.bat`: build no lugar do exe, usado pelo reinício;
- `patch.bat`: os dois passos do build do patch.

Também grava, ao lado do exe, o `hotreload.ini`, com a pasta do fonte e esses comandos. É de lá
que `THotReload.Start([])` lê o que vigiar.

## Console para quem não usa o plugin (`hrctl watch`)

Com `auto=1` no `hotreload.ini`, o exe abre sozinho o console do `watch` ao iniciar.

- Há um `watch` por pasta (mutex), e o QuickEdit do console fica desligado.
- `.pas` salvo vira patch; mudança de estrutura pede **R** (reiniciar).
- Teclas: **P** = patch agora, **R** = reiniciar, **Q** = sair.
- `HOTRELOAD_NOWATCH=1` no ambiente impede a abertura automática.

## Pastas

- `src\`: units que entram no programa (`HotReload`, `HotReload.DfmModel`, `HotReload.DfmApply`,
  `HotReload.Control`, `HotReload.Patch`)
- `tools\hrctl\`: CLI (`build\build-hrctl.bat`)
- `tools\ide\`: plugin da IDE (`build\build-ide.bat`)
- `demo\`: app de exemplo (`build\dev-demo.bat`)
- `tests\`: testes automáticos (`build\build-tests.bat`)
