# CodexBar — estado e segurança

## Prioridade Alta
1. `pz ai doctor` agrega MCP + saúde/status CodexBar em JSON v2 — concluído.
2. `pz ai repair` inclui reparo seguro CodexBar — concluído; nunca instala QML.
3. Instalação CLI: release Linux verificada; fallbacks Homebrew/Cargo — concluído.

## Prioridade Média
4. `setup` enriquece config e detecta sessões Codex/Claude/Z.ai — concluído.
5. Watchdog prioriza `phasezero-notify`, depois `notify-send`/`zenity` — concluído.

## Prioridade Baixa
6. KodexBar não é adicionado nem atualizado automaticamente. Decisão permanente de segurança.
7. Testes: hashes asset/binário, auth redigido, health, watchdog isolado, setup sem QML e bloqueio de live update — concluído.
8. UI nativa: status, saúde, setup CLI/config, auth, repair e watchdog — concluído.

## Incidente KDE de 2026-07-12

- Pacote QML foi atualizado às 10:29:29; sessão Plasma encerrou às 10:29:34.
- Instância órfã `org.kde.plasma.kodexbar` permaneceu no layout do desktop.
- Correção: backup do layout, remoção via Plasma DBus ou `kwriteconfig6` somente para entrada órfã, confirmação e desinstalação do pacote.
- `setup`, `update` e `repair` agora operam somente CLI/config. Instalação do plasmoid exige ação explícita e recusa substituição ao vivo.
- PhaseZero UI nativa é superfície suportada para CodexBar; plasmoid externo é opcional.

## Commits base
- b374d21 fix: expose authenticated proxies in Linux IDEs
- 7f84550 fix(linux): harden SteamOS plugins and control center
- e2a1060 feat(linux): ship control center integrations and proxy suite
- 493cb6c integração inicial incompleta; corrigida na revisão posterior ao incidente KDE.
