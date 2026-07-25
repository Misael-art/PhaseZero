# WinBoat, WinPodX e Podman

PhaseZero instala AppImages oficiais verificadas pelo tamanho e SHA-256 publicado pela API do GitHub. Instalação fica no usuário. Podman opera rootless. Nenhum token, senha do Windows ou chave de licença entra no repositório.

```bash
linux/pz windows-vm apps setup
linux/pz windows-vm apps doctor
```

Perfil Steam Deck LCD:

- 4 vCPU e 4 GiB por guest;
- autostart desligado;
- política de um guest Windows por vez;
- WinPodX com oito sessões, parada após 30 minutos ocioso, FreeRDP nativo, escala 135%, multimonitor desligado e multitouch;
- Windows em português do Brasil, fuso `America/Sao_Paulo`, disco SSD virtual de 64 GiB;
- armazenamento WinPodX em `~/.local/share/winpodx/storage`;
- WinBoat usa Podman, escala 125%, animações desligadas e monitoramento RDP.

WinBoat e WinPodX gerenciam seus próprios containers. Criar um Podman pod adicional quebraria mapeamentos de portas gerados pelos projetos. Aqui “pod” representa unidade operacional do frontend, não um recurso Kubernetes gerenciado pelo PhaseZero.

Primeiro provisionamento Windows continua interativo. Motivos: aceite da EULA, credenciais e download aproximado de 7,5 GiB. PhaseZero configura host e frontend, mas não aceita licença nem grava senha pelo usuário. Depois da primeira execução, mantenha apenas um entre VM libvirt, WinBoat e WinPodX ativo.

## Intercâmbio de arquivos

VM libvirt usa rede NAT `default`. Gateway permanece estável mesmo quando DHCP do guest muda:

- `\\192.168.122.1\PZExchange` — diretório dedicado `~/Shared/WindowsVM`;
- `PZHome`, `PZSDCard`, `PZRemovable`, `PZMedia`, `PZMounts` — recursos amplos existentes;
- SPICE WebDAV — canal persistente; requer `spice-webdavd` no Windows;
- WinPodX — `\\tsclient\home` e `\\tsclient\media` via redirecionamento FreeRDP.

Samba aceita somente loopback e `192.168.122.0/24`. Firewalld abre serviço Samba apenas na zona `libvirt`. NIC e1000e permanece por compatibilidade; mude para VirtIO somente após instalar driver NetKVM no guest.

## Tela Steam Deck LCD

Sessão direta detecta `Jupiter` sem monitor externo e inicia Gamescope DRM em 1280×800 com `--force-orientation right`. Atualize runtime instalado:

```bash
phasezero-admin linux/pz windows-vm graphics runtime install --json
linux/pz windows-vm graphics doctor --json
```

