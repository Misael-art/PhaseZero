# Resumo do plano: aceleração gráfica no provision Windows VM

## Realidade objetiva

| Profile | Accel no Steam Deck | Status |
|---|---|---|
| QXL (atual) | ❌ software (sem aceleração) | funciona, lento |
| virtio-gl (virgl) | ⚠️ OpenGL parcial (sem Vulkan/D3D) | P0 - será estável |
| Venus (Vulkan) | ✅ Vulkan | P1 experimental (futuro) |
| VFIO Looking Glass | — | impossível no Deck (APU única) |

## O que resolve (P0 honesto)

1. `--graphics` efetivo no relaunch:
   - `compat` → `-vga qxl -display gtk`
   - `virtio-gl` → `-device virtio-vga-gl -display gtk,gl=on`
   - Desconhecido → erro não-zero (sem fallback silencioso)

2. Headless invariant: setup/drivers/tweaks sempre `-vga qxl -display none` (Windows PE/OOBE tolera)

3. Preflight fail-loud (run_validate):
   - `/dev/kvm` acessível
   - `/dev/dri/renderD*` acessível (mesa/virgl)
   - `qemu -device help | grep virtio-vga-gl`
   - `virglrenderer` na ldconfig
   - AMDGPU driver bound (warning se ausente)
   - Falha → `return 1`, operação bloqueada

4. Log honesto uma linha:
   - `"GPU acceleration: NONE (QXL)"`
   - `"GPU acceleration: virgl (OpenGL only; no Vulkan/D3D)"`

5. Pós-driver QGA check:
   - `Get-PnpDevice -Class Display` via guest-exec
   - Se "Microsoft Basic Display Adapter" sob virtio-gl → WARN logado

6. `graphicsResolved` persistido no operation.json (profile, vgaDevice, displayArg, accelLog)

## Non-goals (P1)

- Venus (Vulkan paravirtual): `graphics.sh plan --profile virtio-venus` funciona,
  mas `apply` bloqueado. Pré-requisitos: kernel 6.7+, mesa 23+, QEMU com venus.
- VanGogh APU (Steam Deck) não faz VFIO — Venus é o único caminho de aceleração,
  ainda experimental.
- crosvm/rutabaga não estão nas dependências (futuro).

## Comportamento existente mantido

- `setup/drivers/tweaks` continuam headless
- Drivers instalados via QGA (virtio-win) antes de qualquer GPU check
