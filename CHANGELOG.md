# Changelog

## v0.1.0

Primeira versão pública.

- `.dfm` aplicado na tela aberta: propriedades, componentes novos e removidos, troca de pai,
  propriedade apagada volta ao padrão, posições convertidas para o DPI e as âncoras em execução.
- Troca de código sem reiniciar (`patch`): só as rotinas alteradas, com objetos, telas e globais
  preservados. Mudança de estrutura é detectada e recusada.
- Reinício rápido (`restart`): se o build falhar, o exe antigo continua aberto. Se passar, as
  telas voltam com os campos digitados, as abas e a posição, inclusive telas encaixadas em abas e
  depois de um login.
- Plugin da IDE (Delphi 12): menu Hot Reload, patch automático ao salvar e resultado na janela
  Messages.
- `hrctl`: canal de controle para agentes de IA e console `watch` para quem não usa o plugin.
- Funciona com exe que pede elevação (`requireAdministrator`).
