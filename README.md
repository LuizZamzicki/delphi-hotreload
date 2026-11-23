# Delphi Hot Reload

Altere telas e código de um programa VCL **com ele rodando**: sem fechar o exe, sem navegar de
novo até a tela e sem perder o que estava digitado.

- **Salvou um `.dfm`:** a tela aberta muda na hora. Funciona para propriedade, posição e
  componente novo ou removido.
- **Salvou um `.pas`:** o código novo das rotinas alteradas passa a valer no exe que está
  rodando. Objetos, telas e variáveis globais continuam como estavam.
- **Mudou a estrutura** (campo novo, método virtual, `published`, variável global): um reinício
  rápido recompila, reabre o exe e devolve as telas abertas com o que estava digitado, as abas e
  a posição.

Tudo isso pela própria IDE: o resultado aparece na janela **Messages**, e um erro de compilação
leva à linha com duplo clique.

## Requisitos

- Delphi 12 Athens. O plugin é compilado para essa versão.
- Aplicações **VCL Win32**.
- Windows 10 ou 11.

## Instalação

1. Baixe o `.zip` da [última Release](https://github.com/LuizZamzicki/delphi-hotreload/releases)
   e extraia numa pasta fixa, por exemplo `C:\delphi-hotreload`.
2. **Com o Delphi fechado**, rode `instalar.bat`.
3. Abra o Delphi: aparece o menu **Hot Reload**.

Para remover, rode `desinstalar.bat` com o Delphi fechado.

## Uso

1. Abra o projeto e clique em **Hot Reload > Ativar neste projeto**. Isso faz duas coisas:
   - cria a configuração de build **HotReload**, filha da Release;
   - acrescenta as units do hot reload ao `.dpr`, dentro de `{$IFDEF HOTRELOAD}`.

   Debug e Release continuam iguais, e o build de produção não leva nada do hot reload.
2. Escolha a configuração **HotReload**, no Project Manager (Build Configurations) ou no combo da
   barra de ferramentas, e rode o programa (F9 ou Ctrl+Shift+F9).
3. Edite e salve. Acompanhe na janela **Messages**, aba **Hot Reload**.

Se o programa precisa de arquivos ao lado do exe (`.ini`, DLLs, banco), aponte o *Output
directory* da configuração HotReload para uma pasta que os tenha.

## O que acontece em cada mudança

| Você salvou | O que acontece | Tempo típico |
|---|---|---|
| `.dfm` | aplicado na tela aberta, sem compilar | instantâneo |
| corpo de método no `.pas` | código trocado no exe vivo, sem reiniciar | 1 s (projeto pequeno) a 20 s (2 milhões de linhas) |
| estrutura de classe, `published`, global | **Hot Reload > Reiniciar**: recompila e reabre nas mesmas telas | o tempo do build incremental |
| erro de compilação | nada é aplicado; o exe continua como estava | — |

## Limitações

- Só VCL Win32 e Delphi 12.
- A troca de código sem reiniciar vale para o **corpo de rotinas**. O código de `initialization`
  não roda de novo.
- Um evento novo ligado no `.dfm` só passa a funcionar depois que o método existir compilado,
  ou seja, depois de um reinício.
- O reinício não reabre telas modais nem restaura controles ligados a banco (`DataSource`),
  para não mexer em dataset.
- Com o depurador da IDE ligado, uma rotina com menos de 5 bytes é desviada por `INT3`, e o
  depurador para nela; é só continuar.
- Hot reload é para desenvolvimento. Antes de distribuir, compile normalmente pela Release.

## Agentes de IA

O exe com hot reload abre um canal de controle, e o CLI `hrctl` permite que um agente (Claude
Code, por exemplo) veja e mexa nas telas vivas sem tirar print nem navegar. Os comandos permitem
listar telas, ler o DFM vivo, ler e escrever propriedades, clicar, aplicar `.dfm`, trocar código
e reiniciar. Veja [docs/AGENTES.md](docs/AGENTES.md).

## Sem o plugin

O plugin é a forma mais simples, mas tudo funciona pela linha de comando:

```bat
hrctl setup --project C:\Fontes\MeuProjeto.dproj --config HotReload
```

Isso prepara os comandos de build e grava um `hotreload.ini` ao lado do exe. Ao rodar, o exe
abre sozinho um console (`hrctl watch`) que aplica as mudanças a cada arquivo salvo.

## Compilar do código-fonte

```bat
build\build-hrctl.bat     rem tools\hrctl\bin\hrctl.exe
build\build-ide.bat       rem tools\ide\bin\HotReloadIDE.bpl (e registra a pasta para o plugin)
build\build-tests.bat     rem testes automáticos
build\dev-demo.bat        rem abre o demo com o console de hot reload
```

Os scripts acham o Delphi 12 pelo registro (ou pela variável `BDS`).

## Como funciona

Em resumo:
- **`.dfm`:** o exe compara o DFM salvo com o que a tela reflete e aplica só a diferença na
  instância viva, por um `TReader` próprio.
- **Código:** o build gera os `.obj` das units alteradas. As rotinas que mudaram são copiadas
  para a memória do exe, e a rotina antiga é desviada com um `JMP`.
- **Reinício:** o estado das telas é salvo antes e restaurado depois.

Os detalhes estão em [docs/COMO-FUNCIONA.md](docs/COMO-FUNCIONA.md).

## Licença

[MIT](LICENSE).
