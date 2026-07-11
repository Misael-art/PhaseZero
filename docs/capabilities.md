# Capabilities Linux

Contrato: `pz.capabilities/v1`.

## Fluxo

```text
detect → catalog/status → plan → apply → verify → rollback
```

- `detect`: fatos do host; nenhuma mutação.
- `catalog`: recursos, compatibilidade e fonte preferida.
- `status`: inclui presença instalada.
- `plan`: expande perfil/dependências, valida conflitos e disponibilidade, persiste preview privado e gera token.
- `apply`: exige ID + token; revalida host/fonte antes de executar.
- `verify`: consulta fontes e serviços registrados pela operação.
- `rollback`: exige token próprio e atua somente sobre mudanças registradas pela operação.

## Manifesto

JSON máximo 256 KiB, arquivo regular, sem symlink:

```json
{
  "schema": "pz.capabilities/v1",
  "description": "Minha workstation",
  "profiles": ["gaming-core", "developer"],
  "capabilities": ["backup.rclone"],
  "policy": {"maxRisk": "elevated", "allowReboot": false}
}
```

Campos desconhecidos falham. IDs desconhecidos falham. Dependências são ordenadas antes do consumidor. Conflitos selecionados bloqueiam o plano.
`maxRisk` limita risco agregado; `allowReboot: false` bloqueia recursos que recomendam ou exigem reinicialização. Planos expiram após 24 horas.

## Segurança

- Providers: pacote assinado da distribuição ou Flatpak/Flathub já configurado.
- Sem `curl | shell`, AUR automático, `eval` ou shell construído por entrada.
- Argumentos seguem vetores argv.
- Aplicação elevada usa bridge PhaseZero/PolicyKit.
- Estado alvo respeita usuário original após elevação.
- Diretórios `0700`; registros `0600`; escrita atômica.
- Saída limitada e diretório pessoal redigido.
- Pacotes preexistentes nunca entram na lista de rollback.
- Ativação de serviço permitida somente por receita fixa e reversível.
- Firewall, rede, boot/kernel e autenticação remota permanecem ações avançadas explícitas.

## Portabilidade

Catálogo separa compatibilidade, fonte e provider. Linux oferece Arch, Debian, Fedora, openSUSE e fallback Flatpak. Sistemas imutáveis preferem Flatpak e bloqueiam drivers incompatíveis. UI filtra por `platforms`; implementação Windows futura pode adicionar providers sem misturar chamadas Unix na camada visual.
