# Plano: UX desktop Steam Deck — atalhos garantidos, OSD, tray e ditado por voz

Data: 2026-07-04
Status: avaliado no host real (Jupiter, Manjaro/BigLinux, KDE Plasma 6 Wayland, locale pt_BR.UTF-8). Nenhuma feature implementada ainda; este plano registra as provas de viabilidade e a arquitetura.

## Objetivo

Garantir operacionalidade plena do modo desktop em host sem teclado/mouse físico:

1. Atalhos estilo SteamOS desktop (Valve e similares) funcionando de forma verificável.
2. OSD discreto e moderno sinalizando o atalho ativado.
3. Chaves no system tray: tabela de atalhos em overlay e liga/desliga do teclado virtual.
4. Ditado por voz (fala → texto na janela focada), coexistindo com o teclado, no idioma do host.

## Provas de viabilidade executadas no host (2026-07-04)

| Bloco | Resultado |
|---|---|
| OSD nativo Plasma (`qdbus6 org.kde.plasmashell /org/kde/osdService showText`) | OK — toast central discreto, screenshot validado, zero dependência nova |
| Overlay QML frameless translúcido via `qml6` (tabela de atalhos) | OK — renderizou no Wayland, fecha por toque, screenshot validado |
| Atalhos KDE nativos (`kglobalshortcutsrc`) | GAP — nenhum atalho `phasezero-*` registrado neste host; `install-hotkeys.sh` precisa de repair + verificação |
| sxhkd | Inútil aqui (X11-only; sessão é Wayland) |
| wvkbd / wtype | Impossível no KWin (não expõe `zwp_virtual_keyboard_manager_v1`) |
| `ydotoold` como usuário comum | OK — `/dev/uinput` já tem ACL `user:misael:rw-`; digitou em kitty focado sem root |
| `ydotool type` com texto pt-BR | FALHA — assume keymap US; com ABNT2 mutila acentos e pontuação ("ação café" → "ao caf") |
| Clipboard + `ydotool key` Ctrl+Shift+V (keycodes puros) | OK — "ditado pt-BR: ação café maçã não — funciona" chegou íntegro no terminal focado |
| Mic | OK — fonte PipeWire `mic-biglinux` presente |
| Engines de voz nos repos oficiais | `whisper.cpp 1.7.6`, `vosk-api`/`python-vosk 0.3.50` disponíveis via pacman |
| Tray | `kpackagetool6` + módulo QML `plasma5support` presentes → plasmoid nativo viável; `yad --notification` como fallback |
| Socket ydotoold | Atenção: limite de 108 bytes no caminho do Unix socket — usar `$XDG_RUNTIME_DIR/pz-ydotoold.sock` |

## Arquitetura proposta

### Fase 1 — Atalhos garantidos + OSD de atalho

- `pz_osd <icone> <texto>`: helper (novo `linux/lib/osd.sh` ou em `input-actions.sh`) chamando o osdService do Plasma; fallback `notify-send`.
- Instrumentar as ações de `input-actions.sh`/modos (`keyboard`, `handheld`, `docked-*`, `console`, futuro `dictation`) para emitir OSD ao disparar ("⌨ Teclado Virtual ativado", etc.).
- `install-hotkeys.sh`: após gravar `kglobalshortcutsrc`, verificar de fato as entradas e reportar; gerar `~/.config/phasezero/shortcuts.json` como fonte única (atalho, descrição, comando) para a tabela overlay.
- Doctor/repair-plan: check STEAMOS de atalhos ausentes → sugerir `pz steamdeck hotkeys install`.
- Novos atalhos: `Ctrl+Alt+F7` ditado, `Ctrl+Alt+F8` tabela de atalhos.
- Nota honesta: combos Steam+X da Valve exigem Steam client rodando (Steam Input); a camada PhaseZero usa atalhos KDE nativos e funciona sem Steam — este é o "similares".

### Fase 2 — Overlay tabela de atalhos + system tray

- `linux/steamdeck/cheatsheet.qml` (protótipo já validado): janela frameless translúcida sempre-no-topo, lista gerada de `shortcuts.json`, fecha por toque; `pz steamdeck cheatsheet (show|hide|toggle)` via `qml6`.
- Plasmoid `assets/steamdeck/plasmoid/org.phasezero.deckcontrols/` com switches: Teclado virtual, Tabela de atalhos, Ditado — executando `pz` via `plasma5support`; instalação com `kpackagetool6` por `pz steamdeck tray install`. Fallback: script `yad --notification` com menu.

### Fase 3 — Ditado por voz (pt-BR e idioma do host)

- `linux/ai/setup-dictation.sh`: instala `python-vosk` + `ydotool` (repos oficiais), baixa modelo Vosk pelo `$LANG` (pt_BR → `vosk-model-small-pt-0.3`, ~50 MB), instala serviço user `pz-ydotoold` (socket curto em `$XDG_RUNTIME_DIR`).
- `pz-dictation` (Python, sem dependência fora dos repos): captura PipeWire 16 kHz → Vosk streaming → por frase: salva clipboard, `wl-copy` texto, `ydotool key` Ctrl+Shift+V (terminais) ou Ctrl+V (modo geral), restaura clipboard; OSD "🎤 Ditado ativo/pausado".
- `pz steamdeck dictation (start|stop|toggle|status)` + atalho `Ctrl+Alt+F7` + switch no tray. Coexiste com o teclado virtual (são injetores independentes).
- Doctor: modelo presente, mic presente, serviço ativo.
- Upgrades futuros opcionais: `dotool` (AUR) para digitação real unicode tecla-a-tecla; `whisper.cpp` (repo oficial) como modo "alta precisão" por trechos.

## Riscos e limitações

- OSD e plasmoid pressupõem Plasma; fallbacks: `notify-send` e `yad`.
- Clipboard-paste sobrescreve o clipboard por instantes (mitigado com salvar/restaurar; janela de corrida pequena se o usuário copiar algo exatamente durante a frase).
- Vosk small-pt tem precisão moderada; suficiente para comandos/frases curtas, upgrade via whisper.cpp depois.
- nerd-dictation não está no PyPI; preferimos script próprio com `python-vosk` (menos dependência externa).

## Estimativa

Fase 1 ~0,5 dia; Fase 2 ~1 dia (plasmoid é o grosso); Fase 3 ~1 dia com validação real de mic/modelo.
