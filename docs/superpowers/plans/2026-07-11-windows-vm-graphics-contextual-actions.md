# Windows VM — plano de ações gráficas contextuais

**Data:** 2026-07-11  
**Estado:** planejado  
**Alvo:** UI nativa Linux/SteamOS e CLI `pz windows-vm graphics`

## 1. Resultado

UI deixa de exibir comandos gráficos como lista plana. `graphics doctor --json` produz estado e capacidades. Página Windows VM escolhe próxima ação útil:

- aplicar perfil compatível;
- testar VirtIO GL sem persistir configuração;
- reverter última mudança PhaseZero;
- validar drivers e integração dentro do guest;
- atualizar runtime do host;
- reparar integração host/guest.

Uma ação primária por estado. Ações secundárias permanecem acessíveis. Ação impossível fica desabilitada com motivo. Nenhuma dessas operações altera GRUB, EFI, initramfs, SDDM ou bind VFIO.

## 2. Evidência e lacunas

Já existe no trabalho local:

- `graphics doctor --json`, com perfil configurado/efetivo, checks e runtime;
- aplicação `compat` e teste GL por lançamento raw QEMU dry-run;
- status, instalação e rollback do runtime com SHA-256 e backup;
- guia manual de drivers do guest;
- reparo de shares via `windows-vm shares repair`.

Falta:

- contrato de capacidades consumível pela UI, sem interpretar comandos textuais;
- probe estruturado do guest;
- diagnóstico agregado da integração SPICE/QEMU agent/rede/shares/USB;
- ledger único para descobrir se rollback existe e qual escopo restaura;
- componente visual que ordene ações pelo estado;
- testes da matriz de decisão.

## 3. Modelo de contexto

Adicionar ao envelope do doctor:

```json
{
  "schemaVersion": 2,
  "status": "needsrepair",
  "configuredProfile": "virtio-gl",
  "effectiveProfile": "compat",
  "capabilities": {
    "compat": {"available": true, "recommended": true, "reason": "perfil experimental bloqueado"},
    "glTest": {"available": true, "recommended": false, "reason": "host elegível"},
    "rollback": {"available": true, "scope": "runtime", "backupId": "20260711-120000-42"},
    "guestValidation": {"available": false, "reason": "guest desligado"},
    "runtimeUpdate": {"available": true, "recommended": true, "reason": "2 artefatos divergentes"},
    "integrationRepair": {"available": true, "recommended": false, "reason": "share SMB indisponível"}
  },
  "primaryAction": "windows.graphics.runtime-install",
  "recommendedActionIds": [
    "windows.graphics.runtime-install",
    "windows.graphics.compat"
  ]
}
```

Regras:

- CLI emite IDs do catálogo, não linhas de shell.
- `reason` sempre legível e sanitizado.
- `available=false` exige motivo.
- UI não infere elegibilidade usando texto, título ou stderr.
- versão desconhecida degrada para ações read-only: doctor, status e guia.

## 4. Matriz de decisão

| Contexto detectado | Primária | Secundárias | Bloqueadas/ocultas |
|---|---|---|---|
| KVM/QEMU ausente | Reparar integração | Atualizar runtime | Testar GL, validar guest |
| Perfil desconhecido ou experimental bloqueado | Aplicar compat | Atualizar runtime, reverter | Testar GL até host elegível |
| Runtime ausente/divergente | Atualizar runtime | Aplicar compat, reverter se backup | Validar guest até sessão utilizável |
| Host GL elegível, guest desconhecido | Testar GL | Aplicar compat, validar guest após boot | Aplicação persistente GL |
| VM ligada e agente guest acessível | Validar guest | Reparar integração | Atualizar runtime se sessão depende dos arquivos ativos |
| SPICE/agent/share/USB degradado | Reparar integração | Validar guest, aplicar compat | Nenhuma ação destrutiva automática |
| Última mutação falhou e backup válido existe | Reverter | Aplicar compat | Rollback de escopo não relacionado |
| Tudo saudável | Validar guest | Testar GL opcional, status | Reparos não recomendados |

Prioridade quando múltiplos problemas coexistem:

```text
bloqueio host → runtime → perfil compat → integração → guest → teste GL
```

Rollback interrompe prioridade normal quando `lastOperation.status=failed` e backup correspondente está íntegro.

## 5. Plano por ação

### 5.1 Aplicar compat

**Mostrar quando:** perfil configurado não é `compat`, perfil efetivo caiu para compat, tela preta foi reportada ou probe gráfico falhou.

**Comando:**

```text
pz windows-vm graphics apply --profile compat --json
```

**Preview:** `graphics plan --profile compat --json`.

**Pós-condição:** doctor retorna `effectiveProfile=compat`; configuração persistida contém somente perfil conhecido. VM em execução não é reiniciada automaticamente.

**Reversão:** restaurar perfil anterior somente se ledger registrar valor válido. Perfil experimental nunca é reaplicado automaticamente.

### 5.2 Testar GL

**Mostrar quando:** KVM, render node, `virtio-vga-gl` e backend GTK GL estão disponíveis; domínio libvirt persistente não será alterado.

**Fluxo:**

1. preflight read-only;
2. mostrar disco, memória, display e blockers;
3. iniciar sessão raw QEMU transitória após confirmação;
4. registrar resultado host e solicitar validação guest;
5. encerrar teste sem mudar perfil persistente.

**Comandos:**

```text
pz windows-vm graphics test-gl --dry-run --json
pz windows-vm graphics test-gl --confirm TOKEN --json
```

Implementação pode reutilizar `windows-vm launch --raw-qemu --graphics virtio-gl --experimental`, mas contrato público pertence a `graphics test-gl`. Evita UI conhecer montagem interna do launch.

**Sucesso host:** QEMU inicia, display GL abre, processo permanece estável durante janela mínima. Isso não prova aceleração 3D no Windows.

**Reversão:** encerrar processo transitório. Sem escrita de perfil.

### 5.3 Reverter

**Mostrar quando:** ledger possui backup íntegro criado por operação PhaseZero e escopo corresponde ao incidente atual.

**Escopos:** `runtime`, `integration`, `profile`. UI mostra exatamente arquivos/configurações restaurados.

**Comando:**

```text
pz windows-vm graphics rollback --operation-id ID --dry-run --json
pz windows-vm graphics rollback --operation-id ID --confirm TOKEN --json
```

`runtime rollback --backup` permanece alias compatível. Rollback valida manifest, hashes, paths permitidos e versão antes de escrever. Nunca aceita diretório arbitrário.

**Pós-condição:** doctor executado automaticamente. Falha parcial mantém backup e produz instrução manual.

### 5.4 Validar guest

**Mostrar quando:** VM está ligada. Ação continua disponível em modo guiado quando agente guest não responde.

**Checks automáticos preferidos:**

- QEMU Guest Agent acessível via libvirt;
- versão Windows e estado de boot;
- dispositivo de vídeo e ausência de erro PnP;
- driver VirtIO GPU DOD/SPICE presente;
- resolução e adaptador ativo;
- DirectX/Direct3D via `dxdiag` estruturado;
- OpenGL via helper PhaseZero assinado ou ferramenta já instalada;
- rede, share PhaseZero e fallback RDP.

**Política:** não habilitar WinRM, RDP, firewall ou baixar executável sem consentimento. Sem canal guest confiável, gerar checklist e permitir importação de relatório local.

**Comandos:**

```text
pz windows-vm graphics guest validate --json
pz windows-vm graphics guest report --input PATH --json
```

**Estados:** `passed`, `partial`, `failed`, `unreachable`. `partial` diferencia ausência de probe OpenGL de falha real.

### 5.5 Atualizar runtime

**Mostrar quando:** artefato ausente ou SHA-256 instalado difere da fonte atual.

**Comandos existentes:**

```text
pz windows-vm graphics runtime status --json
pz windows-vm graphics runtime install --dry-run
pz windows-vm graphics runtime install
```

**Mudança necessária:** instalação emitir JSON versionado, operation ID, backup ID, lista `changed` e `restartRequired`. Cópias usam staging, fsync quando disponível e rename atômico. Backup nasce antes de qualquer escrita.

**Pós-condição:** todos artefatos `current=true`; sessão systemd recarregada somente se necessário. Boot atual não é reiniciado.

### 5.6 Reparar integração

**Mostrar quando:** runtime atual, mas doctor detecta falha em domínio libvirt, SPICE, QEMU agent, shares, rede virtual ou USB redirection.

**Separar plano e aplicação:**

```text
pz windows-vm integration status --json
pz windows-vm integration plan --json
pz windows-vm integration repair --confirm TOKEN --json
```

**Escopo seguro v1:**

- reinstalar arquivos PhaseZero divergentes;
- recriar links de shares;
- validar bloco Samba antes de publicar;
- reparar canais SPICE/USB somente no domínio desligado e com backup XML;
- recarregar serviços afetados;
- preservar disco, firmware, boot order e dispositivos PCI.

Mudança em XML libvirt exige domínio desligado, `virsh dumpxml` salvo, diff visível e rollback. Sem condição segura, ação retorna `manualaction`.

## 6. UI

### 6.1 Página Windows VM

Seção `Gráficos e integração` recebe:

- faixa de saúde: perfil efetivo, runtime, guest e integração;
- card `Recomendado agora`, alimentado por `primaryAction`;
- até três ações secundárias disponíveis;
- disclosure `Outras ações` para planos e diagnóstico;
- histórico da última operação e botão Reverter quando válido.

Botão usa verbo específico: `Aplicar compat`, `Testar GL`, `Validar guest`. Não usar `Executar`.

### 6.2 Estados visuais

- `ok`: verde, ação opcional;
- `needsrepair`: âmbar, reparo recomendado;
- `blocked`: vermelho, motivo e próximo passo;
- `unreachable`: cinza, alternativa guiada;
- carregando: skeleton; timeout não vira diagnóstico negativo.

Após qualquer mutação, UI recarrega doctor e mantém resultado anterior acessível. Falha não dispara próxima ação automaticamente.

### 6.3 Confirmação

- read-only: execução direta;
- teste transitório: confirma uso de recursos e possível tela preta;
- runtime/reparo/rollback: preview obrigatório;
- operação elevada: `phasezero-admin`/`bigsudo`; sem sudo interativo embutido.

## 7. Arquivos previstos

| Arquivo | Mudança |
|---|---|
| `linux/windows-vm/graphics.sh` | schema v2, capabilities, test-gl, guest validate, rollback unificado |
| `linux/windows-vm/windows-vm.sh` | integração status/plan/repair e envelopes JSON |
| `linux/ui_native/models.py` | metadados de ação contextual/capacidade |
| `linux/ui_native/catalog.py` | IDs, comandos, previews e títulos finais |
| `linux/ui_native/pages/workspace.py` | card recomendado e ações filtradas por capacidade |
| `linux/ui_native/result_parser.py` | validação mínima do schema/contexto |
| `tests/linux-windows-vm-graphics.sh` | matriz host/runtime/profile/rollback |
| `tests/linux-windows-vm.sh` | integração e guest degradado |
| `tests/test_linux_native_ui.py` | catálogo e segurança das seis ações |
| `tests/test_native_workspace.py` | seleção contextual e fallback de schema |

Não reativar `WindowsVMPage` específica enquanto registry usa `CatalogWorkspacePage`. Implementação deve ocorrer na superfície realmente montada.

## 8. Sequência de implementação

### Fase A — contratos

- [ ] Fixar schema v2 e fixtures JSON para estados `ok`, `needsrepair`, `blocked`, `unreachable`.
- [ ] Adicionar IDs de ação em `capabilities` e `primaryAction`.
- [ ] Manter schema v1 aceito em modo degradado por uma release.

### Fase B — backend seguro

- [ ] Completar runtime JSON e ledger unificado.
- [ ] Criar `test-gl` transitório.
- [ ] Criar guest validate/report sem habilitação remota implícita.
- [ ] Criar integration status/plan/repair com backup XML.
- [ ] Criar rollback por operation ID.

### Fase C — UI contextual

- [ ] Renderizar faixa de saúde e ação primária.
- [ ] Desabilitar ação indisponível com motivo acessível.
- [ ] Usar rótulos específicos e preview correto.
- [ ] Recarregar contexto após mutação.

### Fase D — validação

- [ ] Testar matriz completa offscreen.
- [ ] Testar CLI com fake QEMU, virsh, sysfs, guest agent e Samba.
- [ ] Testar backup corrompido, operação interrompida e schema desconhecido.
- [ ] Rodar `bash -n`, testes shell Windows VM e suíte Pytest nativa.

## 9. Critérios de aceite

- UI apresenta somente uma recomendação primária coerente por fixture.
- Cada uma das seis intenções possui preview, execução, pós-validação e rollback quando aplicável.
- Guest desligado não aparece como driver quebrado.
- `gl=on` nunca aparece como prova de aceleração guest.
- Reparar integração não modifica domínio ligado.
- Atualizar runtime sempre cria backup antes da primeira escrita.
- Reverter aceita somente operação PhaseZero íntegra e de escopo compatível.
- Nenhum fluxo toca cadeia de boot ou faz bind VFIO.
- Argumentos continuam sem shell e erros/logs permanecem sanitizados.

## 10. Fora de escopo

- aplicar VFIO/Looking Glass;
- alterar GRUB, kernel args, initramfs ou módulos;
- instalar drivers Windows automaticamente pela internet;
- habilitar WinRM/RDP/firewall sem escolha explícita;
- considerar Venus/rutabaga suportados para Windows.
