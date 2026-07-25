# PhaseZero Central de Controle

Aplicativo Linux nativo Qt6/PySide6. Frontend não implementa instalação:
somente chama `linux/pz` com argumentos allowlisted pelo catálogo Python.

## Executar

```bash
linux/pz ui
# ou
python3 -m linux.ui_native
# instalar launcher no usuário atual
packaging/linux/install-user.sh
```

Dependências:

- Python 3.10+
- PySide6 6.6+
- bash e jq
- `phasezero-admin`, `bigsudo` ou `pkexec` para operações elevadas

Instalação recomendada no BigLinux/Arch:

```bash
sudo pacman -S pyside6
linux/pz ai setup admin
```

## Segurança operacional

1. Ação mutável inicia preview seguro.
2. Preview usa `--dry-run`, `plan`, `status` ou auditoria equivalente.
3. Diálogo mostra stdout/stderr integral.
4. Execução real nasce somente após confirmação.
5. Operações root passam por `phasezero-admin`; fallback: `bigsudo`/`pkexec`.
   Chamadas internas a `sudo` usam shim gráfico somente dentro do subprocesso
   da UI; tarefas de usuário continuam no usuário original.
6. Cada execução escreve envelope em
   `${XDG_STATE_HOME:-~/.local/state}/phasezero/control-center/results/`.

## Atalhos

- `Ctrl+F`: busca
- `Ctrl+1`…`Ctrl+9`: categorias
- `Esc`: cancelar operação ou limpar busca
- `Enter`/`Espaço`: executar card focado

## Smoke test

```bash
QT_QPA_PLATFORM=offscreen python3 -m linux.ui_native \
  --smoke-test --screenshot /tmp/phasezero-ui.png
pytest -q tests/test_linux_native_ui.py
```

## Empacotamento

- AppImage: `packaging/linux/appimage/build-appimage.sh`
- Flatpak: `packaging/linux/flatpak/io.phasezero.ControlCenter.yml`
- DEB: `packaging/linux/deb/build-deb.sh`
- RPM: `packaging/linux/rpm/build-rpm.sh`
- AUR: `packaging/linux/aur/PKGBUILD`

Flatpak usa permissões amplas porque administra host. Flathub pode exigir
revisão de sandbox/portal. Pacotes nativos continuam canal recomendado.
AppImage universal deve ser construído na distribuição Linux mais antiga
suportada para manter compatibilidade glibc.
