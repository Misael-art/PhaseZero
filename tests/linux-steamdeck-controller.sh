#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CACHE_HOME="$TMP_ROOT/cache"
export XDG_STATE_HOME="$TMP_ROOT/state"
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export PZ_SCC_CONFIG_DIR="$TMP_ROOT/scc"
export PZ_CONTROLLER_SYSFS_ROOT="$TMP_ROOT/sysfs"
export PZ_CONTROLLER_REVERT_SECONDS=0
mkdir -p "$HOME" "$PZ_CONTROLLER_SYSFS_ROOT"

SCRIPT="$REPO_ROOT/linux/steamdeck/controller-desktop.sh"
PROFILE="$REPO_ROOT/linux/steamdeck/profiles/PhaseZero-Desktop.sccprofile"

fake_controller() {
    local dev="$PZ_CONTROLLER_SYSFS_ROOT/3-3"
    mkdir -p "$dev"
    printf '28de\n' >"$dev/idVendor"
    printf '1205\n' >"$dev/idProduct"
}

echo "=== o perfil versionado é JSON válido e cobre o mapa desktop ==="
jq -e . "$PROFILE" >/dev/null || { echo "FAIL: perfil não é JSON válido" >&2; exit 10; }

# O mapa que o usuário especificou. Cada linha aqui existe porque um botão
# silencioso não falha em lugar nenhum: o controle simplesmente não faz nada
# e a causa só aparece com o Deck na mão.
jq -e '.buttons.A.action == "button(Keys.KEY_ENTER)"' "$PROFILE" >/dev/null || { echo "FAIL: A deve confirmar" >&2; exit 11; }
jq -e '.buttons.B.action == "button(Keys.KEY_ESC)"' "$PROFILE" >/dev/null || { echo "FAIL: B deve cancelar" >&2; exit 12; }
jq -e '.buttons.X.action == "button(Keys.KEY_BACKSPACE)"' "$PROFILE" >/dev/null || { echo "FAIL: X deve apagar" >&2; exit 13; }
jq -e '.buttons.Y.action == "button(Keys.KEY_SPACE)"' "$PROFILE" >/dev/null || { echo "FAIL: Y deve ser espaço" >&2; exit 14; }
jq -e '.buttons.LGRIP.action | contains("KEY_LEFTSHIFT") and contains("KEY_TAB")' "$PROFILE" >/dev/null || { echo "FAIL: L4 deve ser Shift+Tab" >&2; exit 15; }
jq -e '.buttons.RGRIP.action == "button(Keys.KEY_TAB)"' "$PROFILE" >/dev/null || { echo "FAIL: R4 deve ser Tab" >&2; exit 16; }
jq -e '.buttons.LGRIP2.action == "button(Keys.KEY_LEFTMETA)"' "$PROFILE" >/dev/null || { echo "FAIL: L5 deve abrir o menu iniciar" >&2; exit 17; }

# R5 é o pedido explícito de "visão geral das atividades". Meta+W é o atalho
# que o KWin já registra para o efeito Overview.
jq -e '.buttons.RGRIP2.action | contains("KEY_LEFTMETA") and contains("KEY_W")' "$PROFILE" >/dev/null || { echo "FAIL: R5 deve abrir a visão geral" >&2; exit 18; }

# R2 clique esquerdo, L2 clique direito: o usuário pediu R2 como clique
# principal justamente para arrastar sem pressionar o trackpad.
jq -e '.trigger_right.action == "button(Keys.BTN_LEFT)"' "$PROFILE" >/dev/null || { echo "FAIL: R2 deve ser clique esquerdo" >&2; exit 19; }
jq -e '.trigger_left.action == "button(Keys.BTN_RIGHT)"' "$PROFILE" >/dev/null || { echo "FAIL: L2 deve ser clique direito" >&2; exit 20; }
jq -e '.pad_right.action | contains("mouse()")' "$PROFILE" >/dev/null || { echo "FAIL: trackpad direito deve mover o cursor" >&2; exit 21; }
jq -e '.pad_left.action | contains("REL_WHEEL")' "$PROFILE" >/dev/null || { echo "FAIL: trackpad esquerdo deve rolar" >&2; exit 22; }
jq -e '.dpad.action | startswith("dpad(")' "$PROFILE" >/dev/null || { echo "FAIL: direcional deve emitir setas" >&2; exit 23; }

echo "  mapa desktop ok"

echo "=== status reporta ausência de controle sem inventar estado ==="
out="$(bash "$SCRIPT" status)"
jq -e '.controllerPresent == false and .profileInstalled == false' <<<"$out" >/dev/null ||
    { echo "FAIL: status deveria reportar controle ausente: $out" >&2; exit 24; }

fake_controller
out="$(bash "$SCRIPT" status)"
jq -e '.controllerPresent == true' <<<"$out" >/dev/null ||
    { echo "FAIL: status deveria achar o controle falso: $out" >&2; exit 25; }
echo "  status ok"

echo "=== dry-run não escreve perfil nem inicia daemon ==="
bash "$SCRIPT" dry-run >/dev/null
test ! -f "$PZ_SCC_CONFIG_DIR/profiles/PhaseZero-Desktop.sccprofile" ||
    { echo "FAIL: dry-run escreveu o perfil" >&2; exit 26; }
# O dry-run precisa rodar onde não há mapeador nem controle, que é todo runner
# de CI. Exigir o binário aqui transformava um ensaio em erro e derrubava a
# suíte fora de um Deck.
out="$(PZ_SCC_DAEMON_BIN="" bash "$SCRIPT" dry-run 2>&1)" || {
    echo "FAIL: dry-run deveria funcionar sem sc-controller instalado" >&2; exit 36; }
grep -q 'dry-run' <<<"$out" || { echo "FAIL: dry-run silencioso: $out" >&2; exit 37; }
echo "  dry-run ok"

echo "=== o timer de reversão grava o pid certo e sobrevive à shell ==="
# Dois defeitos reais moram aqui. O primeiro: $! depois de setsid é o wrapper,
# que morre assim que faz o fork, então o arquivo apontava para um pid morto e
# 'confirm' não cancelava nada. O segundo: o timer matava o daemon por padrão
# de nome, e a própria linha de comando dele contém esse nome - ele se matava
# antes de reverter. Nenhum dos dois aparece sem um Deck na mão.
fake_bin="$TMP_ROOT/fake-scc-daemon"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin"
chmod +x "$fake_bin"
# SHELLOPTS=monitor liga job control dentro da shell do próprio script. Isso
# importa: com job control cada background vira líder de grupo e o setsid
# precisa forkar, então $! passa a ser o wrapper e não o timer. Sem job control
# os dois coincidem e o defeito fica invisível - que é como ele sobreviveu à
# primeira versão desta suíte e só apareceu rodando à mão no terminal.
env SHELLOPTS=monitor PZ_SCC_DAEMON_BIN="$fake_bin" PZ_CONTROLLER_REVERT_SECONDS=4 \
    bash "$SCRIPT" start >/dev/null 2>&1

revert_pidfile="$PZ_SCC_CONFIG_DIR/phasezero-revert.pid"
test -f "$revert_pidfile" || { echo "FAIL: o start não armou a reversão" >&2; exit 38; }
timer_pid="$(cat "$revert_pidfile")"
kill -0 "$timer_pid" 2>/dev/null ||
    { echo "FAIL: pid $timer_pid registrado não existe (o wrapper do setsid foi gravado)" >&2; exit 39; }

# O timer precisa continuar vivo depois que a shell que chamou start termina.
sleep 1
kill -0 "$timer_pid" 2>/dev/null ||
    { echo "FAIL: o timer morreu junto com a shell; a rede de proteção some em silêncio" >&2; exit 40; }

# E precisa se limpar sozinho ao fim da janela, em vez de deixar
# revertPending mentindo para sempre.
sleep 5
test ! -f "$revert_pidfile" ||
    { echo "FAIL: o timer não removeu o próprio arquivo ao expirar" >&2; exit 41; }
jq -e '.revertPending == false' <<<"$(bash "$SCRIPT" status)" >/dev/null ||
    { echo "FAIL: status ainda reporta reversão pendente depois da janela" >&2; exit 42; }
echo "  reversão ok"

echo "=== confirm cancela o timer de verdade ==="
env SHELLOPTS=monitor PZ_SCC_DAEMON_BIN="$fake_bin" PZ_CONTROLLER_REVERT_SECONDS=30 \
    bash "$SCRIPT" start >/dev/null 2>&1
timer_pid="$(cat "$revert_pidfile")"
bash "$SCRIPT" confirm >/dev/null 2>&1
sleep 1
kill -0 "$timer_pid" 2>/dev/null &&
    { echo "FAIL: confirm deixou o timer vivo; ele ainda derrubaria o perfil" >&2; exit 43; }
test ! -f "$revert_pidfile" || { echo "FAIL: confirm não limpou o arquivo" >&2; exit 44; }
echo "  confirm ok"

echo "=== a unit systemd é a que faz o mapa sobreviver ao login ==="
# Sem unit o mapa vale uma sessão e some no reboot seguinte. Por fora isso não
# parece defeito nenhum: não há erro em lugar algum, o controle apenas volta ao
# lizard mode. Foi assim que "instalado mas não funciona" aconteceu.
export PZ_SYSTEMD_USER_DIR="$TMP_ROOT/systemd"

# O scc-daemon exige o subcomando posicional no fim. Sem ele a unit entra em
# laço de reinício e o start ainda dizia "perfil desktop ativo".
grep -q 'ExecStart=.*PROFILE_DEST start' "$SCRIPT" ||
    { echo "FAIL: a unit precisa terminar em 'start' ou o daemon recusa os argumentos" >&2; exit 45; }
grep -q 'WantedBy=default.target' "$SCRIPT" ||
    { echo "FAIL: a unit precisa de WantedBy para habilitar no login" >&2; exit 46; }
# start não pode declarar sucesso sem olhar: systemd reporta "active" durante
# um laço de reinício.
grep -q 'NRestarts' "$SCRIPT" ||
    { echo "FAIL: start deve checar NRestarts antes de dizer que ativou" >&2; exit 47; }
# confirm é o que persiste; sem enable o mapa morre no fim da sessão.
grep -q 'systemctl --user enable' "$SCRIPT" ||
    { echo "FAIL: confirm deve habilitar o serviço no login" >&2; exit 48; }
# --foreground não escreve pidfile; olhar só o pidfile reporta parado um
# serviço saudável.
grep -q 'service_active || daemon_pid' "$SCRIPT" ||
    { echo "FAIL: daemon_running deve aceitar o serviço systemd, não só o pidfile" >&2; exit 49; }
# a reversão precisa avisar; foi a falta disso que fez o mapa parecer quebrado.
grep -q 'controller-reverted' "$SCRIPT" ||
    { echo "FAIL: a reversão deve anunciar-se" >&2; exit 50; }
grep -q 'controller-reverted)' "$REPO_ROOT/linux/steamdeck/hotkey-actions.sh" ||
    { echo "FAIL: hotkey-actions.sh sem a ação de aviso da reversão" >&2; exit 51; }
echo "  persistência ok"

echo "=== o placeholder PZ_ROOT some do perfil instalado ==="
# shell() precisa de caminho absoluto; um PZ_ROOT literal sobrevivente vira
# um binding que falha em silêncio no meio da sessão.
grep -q 'PZ_ROOT' "$PROFILE" ||
    { echo "FAIL: o perfil versionado deveria conter o placeholder PZ_ROOT" >&2; exit 27; }
rendered="$(sed "s|PZ_ROOT|$REPO_ROOT|g" "$PROFILE")"
grep -q 'PZ_ROOT' <<<"$rendered" &&
    { echo "FAIL: PZ_ROOT sobreviveu à substituição" >&2; exit 28; }
jq -e '.buttons.DOTS.action | contains("hotkey-actions.sh keyboard")' <<<"$rendered" >/dev/null ||
    { echo "FAIL: DOTS deveria chamar o teclado virtual do PhaseZero" >&2; exit 29; }
echo "  substituição de caminho ok"

echo "=== a visão geral tem ação, atalho e registro no KDE ==="
grep -q 'overview)' "$REPO_ROOT/linux/steamdeck/hotkey-actions.sh" ||
    { echo "FAIL: hotkey-actions.sh sem ação overview" >&2; exit 30; }
grep -q 'toggleEffect overview' "$REPO_ROOT/linux/steamdeck/hotkey-actions.sh" ||
    { echo "FAIL: overview deveria alternar o efeito do KWin" >&2; exit 31; }
grep -q 'phasezero-activities-overview.desktop' "$REPO_ROOT/linux/steamdeck/install-hotkeys.sh" ||
    { echo "FAIL: install-hotkeys.sh não registra a entrada da visão geral" >&2; exit 32; }
# O atalho precisa estar nos quatro pontos: desktop entry, kglobalaccel,
# verificação e sxhkd. Uma entrada registrada mas não verificada foi
# exatamente como a política de teclado touch falhou em silêncio antes.
test "$(grep -c 'phasezero-activities-overview.desktop' "$REPO_ROOT/linux/steamdeck/install-hotkeys.sh")" -ge 3 ||
    { echo "FAIL: entrada da visão geral não chegou a todos os pontos de registro" >&2; exit 33; }
grep -q 'Meta+Shift+F9' "$REPO_ROOT/linux/steamdeck/tray.sh" ||
    { echo "FAIL: a tabela de atalhos não lista Meta+Shift+F9" >&2; exit 34; }
echo "  visão geral ok"

echo "=== pz expõe o subcomando controller ==="
grep -q 'controller|controller-desktop' "$REPO_ROOT/linux/pz" ||
    { echo "FAIL: pz não despacha steamdeck controller" >&2; exit 35; }
echo "  dispatch ok"

echo "SUITE PASS"
